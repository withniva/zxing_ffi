# frozen_string_literal: true

module ZXingFFI
  # Runs external programs (+pdftoppm+, +pdfinfo+, +magick+, ...) on untrusted input with the isolation
  # and resource limits listed below. Pure standard library: +Process.spawn+, +IO.pipe+ and threads.
  #
  # What {run} guarantees:
  # - The argument vector goes straight to +execve+; it is never interpreted by a shell, not even when it
  #   has a single element.
  # - The child leads a new process group. Its stdin is +/dev/null+ (or a pipe fed with +stdin_data+) and it
  #   inherits no file descriptor besides stdin, stdout and stderr.
  # - stdout and stderr are drained concurrently, so a chatty child can never deadlock on a full pipe.
  # - A monotonic-clock timeout terminates the whole process group: SIGTERM, then SIGKILL after a grace
  #   period. Processes the child leaves behind in its group are killed as soon as it exits.
  # - stdout can be capped, stderr is truncated, and the address space is limited on Linux.
  # - Whatever happens (success, timeout, limit, or an exception such as +Interrupt+ raised in the caller),
  #   the child is reaped and every pipe and helper thread is released before {run} returns or raises.
  #
  # @example Render a PDF page as PGM
  #   status, pgm, stderr = ZXingFFI::Subprocess.run(
  #     ["pdftoppm", "-gray", "-r", "300", "-f", "1", "-l", "1", "/abs/path/doc.pdf"],
  #     timeout: 60, max_stdout: expected_bytes + 1024, memory_limit: 2 * 1024**3
  #   )
  #   raise ZXingFFI::RenderError.new("pdftoppm failed", stderr: stderr, exit_status: status.exitstatus) unless status.success?
  module Subprocess
    # Appended to {Result#stderr} when the child wrote more than +stderr_limit+ bytes.
    TRUNCATION_MARKER = "…[truncated]"

    # Default number of stderr bytes kept by {run}.
    DEFAULT_STDERR_LIMIT = 64 * 1024

    # Default seconds between SIGTERM and SIGKILL when {run} times out.
    DEFAULT_KILL_GRACE = 2

    # Outcome of a finished subprocess. Destructures like a +[status, stdout, stderr]+ triple:
    #
    #   status, stdout, stderr = ZXingFFI::Subprocess.run(argv, timeout: 5)
    #
    # @!attribute [r] status
    #   @return [Process::Status] how the child ended (exit code, or the signal that killed it)
    # @!attribute [r] stdout
    #   @return [String] everything the child wrote to stdout (BINARY encoding)
    # @!attribute [r] stderr
    #   @return [String] the first +stderr_limit+ bytes of stderr as UTF-8 (invalid bytes replaced with
    #     U+FFFD), followed by {TRUNCATION_MARKER} if the child wrote more
    Result = Data.define(:status, :stdout, :stderr) do
      # Enables multiple assignment: +status, stdout, stderr = Subprocess.run(...)+.
      # @return [Array(Process::Status, String, String)]
      def to_ary
        [status, stdout, stderr]
      end

      # @return [Boolean] whether the child exited normally with status 0
      def success?
        status.success? == true
      end
    end

    class << self
      # Runs +argv+ to completion and captures its output.
      #
      # A non-zero exit status, or death by a signal, is not an error here: inspect {Result#status}.
      #
      # @param argv [Array<String>] executable and arguments. The executable is looked up on PATH unless
      #   it contains a slash. Nothing is interpreted by a shell.
      # @param timeout [Numeric, nil] seconds (monotonic clock) before the process group receives SIGTERM,
      #   followed by SIGKILL +kill_grace+ seconds later. +nil+ waits forever.
      # @param max_stdout [Integer, nil] maximum stdout bytes; the process group is killed as soon as more
      #   arrive
      # @param memory_limit [Integer, nil] address-space limit in bytes (+RLIMIT_AS+), clamped to the
      #   current hard limit. Applied on Linux only: macOS does not enforce +RLIMIT_AS+, so the option is
      #   silently ignored there.
      # @param stdin_data [String, nil] bytes written to the child's stdin, which is then closed. A child
      #   that exits without reading all of it is not an error. Without it, stdin is +/dev/null+.
      # @param env [Hash{String => String, nil}, nil] environment overrides for the child (+nil+ unsets a
      #   variable); everything else is inherited
      # @param stderr_limit [Integer] stderr bytes kept; the rest is read and discarded
      # @param kill_grace [Numeric] seconds between SIGTERM and SIGKILL after a timeout
      # @return [Result]
      # @raise [ArgumentError] if +argv+ is not a non-empty Array of Strings or an option is invalid
      # @raise [LoaderUnavailable] if the executable does not exist or may not be executed
      # @raise [TimeoutError] if the child, or a process holding its pipes open, outlived +timeout+
      # @raise [LimitExceeded] (+limit: :max_stdout+, +value:+ bytes received) if stdout exceeded
      #   +max_stdout+
      # @raise [RenderError] if the process could not be started for another reason (e.g. EAGAIN)
      def run(argv, timeout:, max_stdout: nil, memory_limit: nil, stdin_data: nil, env: nil,
        stderr_limit: DEFAULT_STDERR_LIMIT, kill_grace: DEFAULT_KILL_GRACE)
        Execution.new(
          argv,
          timeout: timeout, max_stdout: max_stdout, memory_limit: memory_limit, stdin_data: stdin_data,
          env: env, stderr_limit: stderr_limit, kill_grace: kill_grace
        ).call
      end

      # Locates an executable without running it (for loader availability checks).
      #
      # A +command+ containing a path separator is checked as given. A bare name is searched in the
      # directories of +PATH+; empty entries are skipped rather than meaning the current directory.
      #
      # @param command [String, nil] executable name or path
      # @return [String, nil] the absolute path of the first executable regular file named +command+ on
      #   PATH, +command+ itself if it contains a path separator and is an executable regular file, or nil
      def which(command)
        command = command.to_s
        return nil if command.empty?
        return (executable_file?(command) ? command : nil) if command.include?(File::SEPARATOR)

        ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |dir|
          next if dir.empty?

          candidate = File.join(dir, command)
          return File.absolute_path(candidate) if executable_file?(candidate)
        end
        nil
      end

      # @return [Boolean] whether this Ruby runs on Linux, the only platform where +memory_limit+ is applied
      def linux?
        RUBY_PLATFORM.include?("linux")
      end

      private

      def executable_file?(path)
        File.file?(path) && File.executable?(path)
      end
    end

    # One {Subprocess.run} call: owns the child, its pipes and the helper threads.
    #
    # Helper threads: a waiter (reaps the child), one reader per output pipe and, with +stdin_data+, a
    # writer. They report to the calling thread through a queue, which it pops with the time left before
    # the deadline.
    #
    # @api private
    class Execution
      # Bytes requested per read from the child's pipes.
      CHUNK_SIZE = 64 * 1024
      # Seconds to wait for a SIGKILLed child to be reaped. A child stuck in the kernel is left to the
      # waiter thread, which reaps it as soon as it dies (that thread is never killed, so no zombie remains).
      REAP_TIMEOUT = 5
      # Seconds to wait for a pipe thread to stop once its pipe is closed, before killing it.
      THREAD_STOP_TIMEOUT = 1

      def initialize(argv, timeout:, max_stdout:, memory_limit:, stdin_data:, env:, stderr_limit:, kill_grace:)
        @argv = check_argv(argv)
        @timeout = check_timeout(timeout)
        @max_stdout = check_integer(:max_stdout, max_stdout, min: 0, allow_nil: true)
        @memory_limit = check_integer(:memory_limit, memory_limit, min: 1, allow_nil: true)
        @stdin_data = check_type(:stdin_data, stdin_data, String)
        @env = check_type(:env, env, Hash)
        @stderr_limit = check_integer(:stderr_limit, stderr_limit, min: 0)
        @kill_grace = check_kill_grace(kill_grace)

        @events = Thread::Queue.new
        @pipes = []
        @io_threads = []
        @stdout = String.new(encoding: Encoding::BINARY)
        @stderr = String.new(encoding: Encoding::BINARY)
        @stderr_bytes = 0
      end

      # @return [Result]
      def call
        # Asynchronous interrupts (Thread#raise, Interrupt, Timeout.timeout) are deferred while resources
        # are acquired and released, so one arriving right after spawn cannot leak the child. They are
        # delivered while waiting.
        Thread.handle_interrupt(Object => :never) do
          start
          Thread.handle_interrupt(Object => :immediate) { wait }
        ensure
          cleanup
        end
      end

      private

      def start
        @deadline = @timeout && monotonic_now + @timeout
        stdout_r, stdout_w = open_pipe
        stderr_r, stderr_w = open_pipe
        stdin_r, stdin_w = open_pipe if @stdin_data
        @pid = spawn_child(in: stdin_r || File::NULL, out: stdout_w, err: stderr_w)
        [stdin_r, stdout_w, stderr_w].compact.each(&:close) # the child's ends
        @waiter = helper_thread("wait") { wait_child }
        @stdout_reader = helper_thread("stdout") { read_stdout(stdout_r) }
        @stderr_reader = helper_thread("stderr") { read_stderr(stderr_r) }
        @io_threads << @stdout_reader << @stderr_reader
        @io_threads << helper_thread("stdin") { write_stdin(stdin_w) } if stdin_w
      end

      def open_pipe
        IO.pipe.each do |io|
          io.binmode
          @pipes << io
        end
      end

      def spawn_child(**redirects)
        options = {**redirects, pgroup: true, close_others: true}
        options[:rlimit_as] = address_space_limit if @memory_limit && Subprocess.linux?
        # The [command, argv0] form always execs directly, even for a single-element argv.
        Process.spawn(@env || {}, [@argv[0], @argv[0]], *@argv.drop(1), **options)
      rescue Errno::ENOENT, Errno::ENOTDIR
        raise LoaderUnavailable, "executable not found: #{@argv[0]}"
      rescue Errno::EACCES, Errno::EPERM
        raise LoaderUnavailable, "executable not permitted: #{@argv[0]}"
      rescue SystemCallError => e
        raise RenderError, "could not start #{command_name}: #{e.message}"
      end

      def address_space_limit
        [@memory_limit, Process.getrlimit(:AS).last].min
      end

      def helper_thread(role, &body)
        Thread.new do
          Thread.current.name = "zxing_ffi subprocess #{role}"
          Thread.current.report_on_exception = false
          # Threads inherit the creator's :never mask; these must stay interruptible (IO#close, Thread#kill).
          Thread.handle_interrupt(Object => :immediate, &body)
        end
      end

      def wait_child
        Process.wait2(@pid).last
      ensure
        @events << :exit
      end

      def read_stdout(io)
        chunk = String.new(capacity: CHUNK_SIZE, encoding: Encoding::BINARY)
        loop do
          io.readpartial(CHUNK_SIZE, chunk)
          if @max_stdout && @stdout.bytesize + chunk.bytesize > @max_stdout
            @stdout_overflow = @stdout.bytesize + chunk.bytesize
            @events << :overflow
            break
          end
          @stdout << chunk
        end
      rescue EOFError
        # every writer (the child and anything it spawned) closed stdout
      ensure
        @events << :stdout
      end

      def read_stderr(io)
        chunk = String.new(capacity: CHUNK_SIZE, encoding: Encoding::BINARY)
        loop do
          io.readpartial(CHUNK_SIZE, chunk)
          room = @stderr_limit - @stderr.bytesize
          @stderr << chunk.byteslice(0, room) if room.positive?
          @stderr_bytes += chunk.bytesize # keep draining past the limit
        end
      rescue EOFError
        # every writer closed stderr
      ensure
        @events << :stderr
      end

      def write_stdin(io)
        io.write(@stdin_data)
      rescue Errno::EPIPE, IOError
        # EPIPE: the child exited or closed stdin early (its exit status tells the story).
        # IOError: the pipe was closed by #cleanup.
      ensure
        close_pipe(io) # EOF for the child
      end

      def wait
        pending = %i[exit stdout stderr]
        until pending.empty?
          event = @events.pop(timeout: time_left)
          case event
          when nil then time_out!
          when :overflow then raise stdout_overflow_error
          when :exit then child_exited
          when :stdout then @stdout_reader.value # re-raises an unexpected reader failure
          when :stderr then @stderr_reader.value
          end
          pending.delete(event)
        end
        Result.new(status: @status, stdout: @stdout, stderr: stderr_text)
      end

      def child_exited
        @status = @waiter.value
        # Anything the child left in its group (e.g. a background job holding our pipes) goes too. After
        # this sweep the group is never signalled again: once empty, its id may be reused.
        signal_group(:KILL)
        @group_released = true
      end

      def time_out!
        signal_group(:TERM)
        signal_group(:KILL) unless finished?(@waiter, @kill_grace)
        raise TimeoutError, "#{command_name} timed out after #{format_seconds(@timeout)}s"
      end

      def stdout_overflow_error
        LimitExceeded.new(
          "#{command_name} wrote more than #{@max_stdout} bytes to stdout",
          limit: :max_stdout, value: @stdout_overflow
        )
      end

      def cleanup
        if @pid
          signal_group(:KILL) # no-op after a normal exit (already swept)
          reap
        end
        @pipes.each { |io| close_pipe(io) } # wakes up any helper still blocked on a pipe
        @io_threads.each { |thread| stop_thread(thread) }
      end

      def reap
        if @waiter
          finished?(@waiter, REAP_TIMEOUT)
        else
          Process.wait(@pid) # the waiter thread could not be started; the group was just killed
        end
      rescue SystemCallError
        nil
      ensure
        @group_released = true
      end

      def signal_group(signal)
        return if @group_released

        Process.kill(signal, -@pid)
      rescue Errno::ESRCH, Errno::EPERM
        # the group is gone (macOS reports EPERM when only zombies are left)
      end

      # Joins +thread+ for up to +limit+ seconds; true if it has ended (with or without an exception).
      def finished?(thread, limit)
        !thread.join(limit).nil?
      rescue
        true
      end

      def close_pipe(io)
        io.close
      rescue IOError, SystemCallError
        nil
      end

      def stop_thread(thread)
        thread.kill unless finished?(thread, THREAD_STOP_TIMEOUT)
      end

      def stderr_text
        text = @stderr.force_encoding(Encoding::UTF_8).scrub
        text << TRUNCATION_MARKER if @stderr_bytes > @stderr_limit
        text
      end

      def time_left
        @deadline && [@deadline - monotonic_now, 0].max
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def command_name
        File.basename(@argv[0])
      end

      def format_seconds(seconds)
        (seconds == seconds.to_i) ? seconds.to_i.to_s : seconds.to_f.round(3).to_s
      end

      def check_argv(argv)
        raise ArgumentError, "argv must be an Array of Strings, got #{argv.class}" unless argv.is_a?(Array)
        raise ArgumentError, "argv must not be empty" if argv.empty?

        argv.each_with_index do |arg, index|
          raise ArgumentError, "argv[#{index}] must be a String, got #{arg.class}" unless arg.is_a?(String)
          raise ArgumentError, "argv[#{index}] contains a NUL byte" if arg.include?("\0")
        end
        raise ArgumentError, "argv[0] must not be empty" if argv[0].empty?

        argv
      end

      def check_timeout(value)
        return nil if value.nil? || value == Float::INFINITY
        return value if value.is_a?(Numeric) && value.real? && value.positive? && value.finite?

        raise ArgumentError, "timeout must be a positive number of seconds or nil, got #{value.inspect}"
      end

      def check_kill_grace(value)
        return value if value.is_a?(Numeric) && value.real? && !value.negative? && value.finite?

        raise ArgumentError, "kill_grace must be a non-negative number of seconds, got #{value.inspect}"
      end

      def check_integer(name, value, min:, allow_nil: false)
        return value if (allow_nil && value.nil?) || (value.is_a?(Integer) && value >= min)

        raise ArgumentError, "#{name} must be an Integer >= #{min}#{" or nil" if allow_nil}, got #{value.inspect}"
      end

      def check_type(name, value, type)
        return value if value.nil? || value.is_a?(type)

        raise ArgumentError, "#{name} must be a #{type} or nil, got #{value.class}"
      end
    end
    private_constant :Execution
  end
end
