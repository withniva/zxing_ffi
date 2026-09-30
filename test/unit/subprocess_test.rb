# frozen_string_literal: true

require "test_helper"
require "fcntl"
require "pathname"
require "rbconfig"
require "timeout"

class SubprocessTest < Minitest::Test
  Subprocess = ZXingFFI::Subprocess

  # Tolerance for timing assertions on slow CI machines (seconds).
  SLACK = 1.0

  # This checkout's lib, for child Ruby processes that load the gem.
  LIB = File.expand_path("../../lib", __dir__)

  # Stands in for an asynchronous interrupt (Thread#raise, Ctrl-C, Timeout.timeout).
  AsyncInterrupt = Class.new(StandardError)

  # Prepended to Process.singleton_class by #with_spawn_hook; inert unless the current thread set a hook.
  module SpawnHook
    def spawn(...)
      pid = super
      Thread.current[:zxing_ffi_spawn_hook]&.call(pid)
      pid
    end
  end

  # --- capture -------------------------------------------------------------------------------------

  def test_captures_stdout_stderr_and_exit_status
    result = Subprocess.run(["sh", "-c", "echo out; echo err >&2"], timeout: 5)

    assert_instance_of Subprocess::Result, result
    assert_equal "out\n", result.stdout
    assert_equal "err\n", result.stderr
    assert_instance_of Process::Status, result.status
    assert_equal 0, result.status.exitstatus
    assert_same true, result.success?
  end

  def test_result_destructures_into_status_stdout_stderr
    status, stdout, stderr = Subprocess.run(["sh", "-c", "printf a; printf b >&2; exit 3"], timeout: 5)

    assert_equal 3, status.exitstatus
    assert_equal "a", stdout
    assert_equal "b", stderr

    result = Subprocess.run(["true"], timeout: 5)
    assert_equal [result.status, "", ""], result.to_ary
    assert_equal({status: result.status, stdout: "", stderr: ""}, result.to_h)
  end

  def test_non_zero_exit_is_returned_not_raised
    result = Subprocess.run(["sh", "-c", "echo failed >&2; exit 7"], timeout: 5)

    assert_same false, result.success?
    assert_equal 7, result.status.exitstatus
    assert_equal "failed\n", result.stderr
  end

  def test_death_by_signal_is_returned_not_raised
    result = Subprocess.run(["sh", "-c", "kill -KILL $$"], timeout: 5)

    assert_same false, result.success?
    assert_predicate result.status, :signaled?
    assert_equal Signal.list.fetch("KILL"), result.status.termsig
  end

  def test_stdout_is_binary_and_stderr_is_utf8
    script = 'cafe = "caf" + [233].pack("U"); $stdout.write cafe; $stderr.write cafe' # ASCII source: any locale
    result = Subprocess.run(ruby(script), timeout: 5)

    assert_equal Encoding::BINARY, result.stdout.encoding
    assert_equal "café".b, result.stdout
    assert_equal Encoding::UTF_8, result.stderr.encoding
    assert_equal "café", result.stderr
  end

  def test_stdout_preserves_every_byte_value
    result = Subprocess.run(ruby("$stdout.binmode.write((0..255).map(&:chr).join * 64)"), timeout: 5)

    assert_equal Encoding::BINARY, result.stdout.encoding
    assert_equal (0..255).map(&:chr).join.b * 64, result.stdout
  end

  def test_drains_large_stdout_while_stderr_floods_without_deadlock
    script = <<~RUBY
      $stdout.binmode
      $stderr.binmode
      out = "o" * 65_536
      err = "e" * 65_536
      320.times { $stdout.write(out); $stderr.write(err) }
    RUBY
    result = Subprocess.run(ruby(script), timeout: 20)

    assert_predicate result, :success?
    assert_equal 20 * 1024 * 1024, result.stdout.bytesize
    assert_equal result.stdout.bytesize, result.stdout.count("o")
    assert_equal ("e" * Subprocess::DEFAULT_STDERR_LIMIT) + Subprocess::TRUNCATION_MARKER, result.stderr
  end

  def test_truncates_stderr_with_a_marker
    long = Subprocess.run(ruby("$stderr.write('x' * 100)"), timeout: 5, stderr_limit: 10)
    assert_equal "xxxxxxxxxx…[truncated]", long.stderr

    exact = Subprocess.run(ruby("$stderr.write('x' * 10)"), timeout: 5, stderr_limit: 10)
    assert_equal "x" * 10, exact.stderr

    nothing_kept = Subprocess.run(ruby("$stderr.write('x')"), timeout: 5, stderr_limit: 0)
    assert_equal "…[truncated]", nothing_kept.stderr
  end

  def test_scrubs_invalid_utf8_in_stderr
    result = Subprocess.run(ruby('$stderr.write("bad \\xFF\\xFE bytes".b)'), timeout: 5)

    assert_predicate result.stderr, :valid_encoding?
    assert_equal "bad �� bytes", result.stderr
  end

  def test_env_overrides_and_unsets_variables
    script = 'printf %s "${ZXING_FFI_SUBPROCESS_TEST-unset}"'
    with_env("ZXING_FFI_SUBPROCESS_TEST" => "inherited") do
      assert_equal "inherited", Subprocess.run(["sh", "-c", script], timeout: 5).stdout
      assert_equal "override",
        Subprocess.run(["sh", "-c", script], timeout: 5, env: {"ZXING_FFI_SUBPROCESS_TEST" => "override"}).stdout
      assert_equal "unset",
        Subprocess.run(["sh", "-c", script], timeout: 5, env: {"ZXING_FFI_SUBPROCESS_TEST" => nil}).stdout
    end
  end

  def test_collects_output_written_after_the_child_exits
    # A process outside the group (setsid, so the post-exit sweep cannot reach it) writes the last bytes
    # of one stream after the child has exited and the other stream is closed: run waits for both EOFs.
    %w[stdout stderr].each do |late|
      other = (late == "stdout") ? "stderr" : "stdout"
      script = <<~RUBY
        r, w = IO.pipe
        fork do
          r.close
          Process.setsid
          $#{other}.reopen(File::NULL)
          w.close
          sleep 0.2
          $#{late}.write("late")
          $#{late}.flush
        end
        w.close
        r.read
        $#{late}.write("early ")
      RUBY
      result = Subprocess.run(ruby(script), timeout: 5)

      assert_equal "early late", result.public_send(late), "#{late} written after the child exited"
    end
  end

  def test_timeout_nil_waits_without_a_deadline
    assert_equal "ok\n", Subprocess.run(["echo", "ok"], timeout: nil).stdout
  end

  def test_runs_concurrently_from_several_threads
    threads = Array.new(8) do |i|
      Thread.new { Subprocess.run(["sh", "-c", "sleep 0.1; printf #{i}; printf e#{i} >&2"], timeout: 10) }
    end
    results = threads.map(&:value)

    assert_equal (0...8).map(&:to_s), results.map(&:stdout)
    assert_equal (0...8).map { |i| "e#{i}" }, results.map(&:stderr)
  end

  # --- stdin ---------------------------------------------------------------------------------------

  def test_stdin_data_round_trips_through_cat
    assert_equal "hello\n", Subprocess.run(["cat"], timeout: 5, stdin_data: "hello\n").stdout
    assert_equal "", Subprocess.run(["cat"], timeout: 5, stdin_data: "").stdout

    data = Random.new(42).bytes(4 * 1024 * 1024)
    result = Subprocess.run(["cat"], timeout: 20, stdin_data: data)

    assert_predicate result, :success?
    assert_equal data.bytesize, result.stdout.bytesize
    assert data == result.stdout, "stdout differs from stdin_data"
  end

  def test_stdin_is_dev_null_without_stdin_data
    # Point our own stdin at a pipe that never reaches EOF: a child inheriting it would block.
    reader, writer = IO.pipe
    saved_stdin = $stdin.dup
    $stdin.reopen(reader)

    result = Subprocess.run(ruby("print $stdin.read.bytesize, ' ', $stdin.stat.rdev"), timeout: 2)
    assert_equal "0 #{File.stat(File::NULL).rdev}", result.stdout
    assert_equal "", Subprocess.run(["cat"], timeout: 2).stdout
  ensure
    $stdin.reopen(saved_stdin) if saved_stdin
    [saved_stdin, reader, writer].compact.each(&:close)
  end

  def test_child_that_does_not_read_all_of_stdin_is_not_an_error
    data = "x" * (8 * 1024 * 1024)

    assert_predicate Subprocess.run(["true"], timeout: 10, stdin_data: data), :success?
    assert_equal "xxxxx", Subprocess.run(["head", "-c", "5"], timeout: 10, stdin_data: data).stdout
  end

  # --- max_stdout ----------------------------------------------------------------------------------

  def test_max_stdout_allows_output_up_to_the_limit
    assert_equal "12345", Subprocess.run(["printf", "12345"], timeout: 5, max_stdout: 5).stdout
    assert_equal "", Subprocess.run(["true"], timeout: 5, max_stdout: 0).stdout

    error = assert_raises(ZXingFFI::LimitExceeded) do
      Subprocess.run(["printf", "123456"], timeout: 5, max_stdout: 5)
    end
    assert_equal :max_stdout, error.limit
    assert_equal 6, error.value
    assert_equal "printf wrote more than 5 bytes to stdout", error.message
  end

  def test_max_stdout_overflow_kills_the_endless_writer
    in_tmpdir do |dir|
      pid_file = File.join(dir, "pid")
      error = assert_raises(ZXingFFI::LimitExceeded) do
        Subprocess.run(["sh", "-c", 'echo $$ > "$1"; exec yes', "sh", pid_file], timeout: 10, max_stdout: 100_000)
      end

      assert_equal :max_stdout, error.limit
      assert_operator error.value, :>, 100_000
      assert_equal "sh wrote more than 100000 bytes to stdout", error.message
      assert_reaped(read_pids(pid_file).first)
    end
  end

  # --- timeout -------------------------------------------------------------------------------------

  def test_timeout_terminates_the_process_group_including_grandchildren
    in_tmpdir do |dir|
      pid_file = File.join(dir, "pids")
      script = 'sleep 30 & echo $! > "$1"; echo $$ >> "$1"; wait'
      error, elapsed = measure do
        assert_raises(ZXingFFI::TimeoutError) do
          Subprocess.run(["sh", "-c", script, "sh", pid_file], timeout: 0.5, kill_grace: 0.3)
        end
      end

      assert_equal "sh timed out after 0.5s", error.message
      assert_operator elapsed, :>=, 0.5
      assert_operator elapsed, :<, 0.5 + 0.3 + SLACK
      grandchild, child = read_pids(pid_file)
      assert_reaped(child)
      assert_process_gone(grandchild)
    end
  end

  def test_child_ignoring_term_is_killed_after_the_grace_period
    in_tmpdir do |dir|
      pid_file = File.join(dir, "pid")
      script = 'trap("TERM", "IGNORE"); File.write(ARGV[0], Process.pid.to_s); sleep 30'
      _, elapsed = measure do
        assert_raises(ZXingFFI::TimeoutError) do
          Subprocess.run(ruby(script, pid_file), timeout: 0.5, kill_grace: 0.3)
        end
      end

      assert_operator elapsed, :>=, 0.5 + 0.3 - 0.05, "SIGKILL must wait for the grace period"
      assert_operator elapsed, :<, 0.5 + 0.3 + SLACK
      assert_reaped(read_pids(pid_file).first)
    end
  end

  def test_timeout_sends_term_first_and_stops_waiting_once_the_child_exits
    in_tmpdir do |dir|
      log = File.join(dir, "log")
      script = 'trap("TERM") { File.write(ARGV[0], "TERM"); exit!(0) }; File.write(ARGV[0], "ready"); sleep 30'
      _, elapsed = measure do
        assert_raises(ZXingFFI::TimeoutError) { Subprocess.run(ruby(script, log), timeout: 0.5, kill_grace: 5) }
      end

      assert_equal "TERM", File.read(log)
      assert_operator elapsed, :<, 0.5 + SLACK, "must not wait out kill_grace once the child is gone"
    end
  end

  def test_grandchild_ignoring_term_is_killed_too
    in_tmpdir do |dir|
      pid_file = File.join(dir, "pid")
      script = '(trap "" TERM; exec sleep 30) & echo $! > "$1"; wait'
      assert_raises(ZXingFFI::TimeoutError) do
        Subprocess.run(["sh", "-c", script, "sh", pid_file], timeout: 0.5, kill_grace: 0.3)
      end

      assert_process_gone(read_pids(pid_file).first)
    end
  end

  def test_timeout_message_names_the_command_basename
    sleep_path = Subprocess.which("sleep")
    error = assert_raises(ZXingFFI::TimeoutError) do
      Subprocess.run([sleep_path, "5"], timeout: 0.2, kill_grace: 0.1)
    end

    assert_equal "sleep timed out after 0.2s", error.message
  end

  def test_processes_left_behind_by_an_exited_child_are_killed
    # The background sleep inherits stdout; without the sweep the call would block until the timeout.
    result, elapsed = measure { Subprocess.run(["sh", "-c", "sleep 30 & echo $!"], timeout: 10) }

    assert_predicate result, :success?
    assert_operator elapsed, :<, 5
    assert_process_gone(Integer(result.stdout))
  end

  def test_times_out_when_an_escaped_process_keeps_the_pipes_open
    in_tmpdir do |dir|
      pid_file = File.join(dir, "pid")
      # The grandchild leaves the process group (setsid), so it survives the sweep and keeps stdout open.
      # The child exits only once the grandchild has left, so the sweep cannot catch it.
      script = <<~RUBY
        r, w = IO.pipe
        pid = fork { r.close; Process.setsid; w.close; sleep 30 }
        w.close
        r.read
        File.write(ARGV[0], pid.to_s)
      RUBY
      begin
        _, elapsed = measure do
          assert_no_new_threads do # both readers are still blocked when cleanup starts
            assert_raises(ZXingFFI::TimeoutError) do
              Subprocess.run(ruby(script, pid_file), timeout: 0.5, kill_grace: 0.3)
            end
          end
        end

        assert_operator elapsed, :<, 0.5 + SLACK
      ensure
        escaped = File.exist?(pid_file) && read_pids(pid_file).first
        kill_quietly(escaped) if escaped
      end
    end
  end

  # --- exceptions in the caller --------------------------------------------------------------------

  def test_interrupt_in_the_caller_kills_and_reaps_the_child
    in_tmpdir do |dir|
      pid_file = File.join(dir, "pid")
      runner = Thread.new do
        Thread.current.report_on_exception = false
        Subprocess.run(["sh", "-c", 'echo $$ > "$1"; exec sleep 30', "sh", pid_file], timeout: 10)
      end
      pid = wait_for_pid(pid_file)
      runner.raise(Interrupt)

      assert_raises(Interrupt) { runner.join(5) }
      assert_reaped(pid)
    end
  end

  def test_interrupt_arriving_right_after_spawn_cannot_leak_the_child
    spawned = []
    hook = lambda do |pid|
      spawned << pid
      Thread.current.raise(AsyncInterrupt) # lands between spawn returning and the pid being stored
    end
    with_spawn_hook(hook) do
      assert_raises(AsyncInterrupt) { Subprocess.run(["sleep", "30"], timeout: 10) }
    end

    assert_equal 1, spawned.size
    assert_reaped(spawned.first)
  ensure
    spawned.each { |pid| reap_quietly(pid) } # only does something if the child leaked
  end

  def test_ruby_can_exit_mid_run_even_if_an_escaped_process_holds_the_pipes
    # At exit Ruby kills every thread. The helper threads must die even while a process outside the
    # group keeps their pipes open; otherwise #cleanup would block forever closing those pipes.
    in_tmpdir do |dir|
      pid_file = File.join(dir, "pids")
      inner = <<~RUBY
        r, w = IO.pipe
        pid = fork { r.close; Process.setsid; w.close; sleep 30 }
        w.close
        r.read
        File.write(ARGV[0], [pid, Process.pid].join(" "))
        sleep 30
      RUBY
      outer = <<~RUBY
        require "rbconfig"
        require "zxing_ffi"
        argv = [RbConfig.ruby, "--disable=gems,rubyopt", "-e", #{inner.dump}, ARGV[0]]
        Thread.new { ZXingFFI::Subprocess.run(argv, timeout: 60) }
        sleep 0.01 until File.size?(ARGV[0])
      RUBY
      begin
        result = Subprocess.run(ruby(outer, pid_file, lib: true), timeout: 5)

        assert_predicate result, :success?
        assert_process_gone(read_pids(pid_file).last) # the inner child was killed on the way out
      ensure
        read_pids(pid_file).each { |pid| kill_quietly(pid) } if File.exist?(pid_file)
      end
    end
  end

  def test_timeout_timeout_around_run_kills_and_reaps_the_child
    in_tmpdir do |dir|
      pid_file = File.join(dir, "pid")
      assert_raises(Timeout::Error) do
        Timeout.timeout(0.3) do
          Subprocess.run(["sh", "-c", 'echo $$ > "$1"; exec sleep 30', "sh", pid_file], timeout: 10)
        end
      end

      assert_reaped(read_pids(pid_file).first)
    end
  end

  def test_releases_threads_and_file_descriptors_on_every_path
    exercise = lambda do
      Subprocess.run(["echo", "hi"], timeout: 5)
      Subprocess.run(["cat"], timeout: 5, stdin_data: "x" * 200_000)
      assert_raises(ZXingFFI::TimeoutError) { Subprocess.run(["sleep", "5"], timeout: 0.2, kill_grace: 0.1) }
      assert_no_new_threads do # the writer is blocked on a full stdin pipe when the timeout hits
        assert_raises(ZXingFFI::TimeoutError) do
          Subprocess.run(["sleep", "5"], timeout: 0.2, kill_grace: 0.1, stdin_data: "x" * 1_000_000)
        end
      end
      assert_raises(ZXingFFI::LimitExceeded) { Subprocess.run(["yes"], timeout: 5, max_stdout: 10) }
      assert_raises(ZXingFFI::LoaderUnavailable) { Subprocess.run(["zxing-ffi-no-such-tool"], timeout: 5) }
    end
    exercise.call # warm up anything created lazily
    GC.start
    GC.disable # a leaked IO must not be closed by its finalizer before we count
    threads = Thread.list.size
    fds = open_fd_count
    2.times { exercise.call }

    assert_equal threads, Thread.list.size, "helper threads leaked"
    assert_equal fds, open_fd_count, "file descriptors leaked"
  ensure
    GC.enable
  end

  # --- isolation -----------------------------------------------------------------------------------

  def test_shell_metacharacters_are_passed_literally
    argument = "$(whoami); ls * | wc -l > /dev/null && `id` 'q' \"dq\" \\"
    assert_equal "#{argument}\n", Subprocess.run(["echo", argument], timeout: 5).stdout
  end

  def test_single_element_argv_is_not_run_through_a_shell
    in_tmpdir do |dir|
      marker = File.join(dir, "pwned")
      error = assert_raises(ZXingFFI::LoaderUnavailable) { Subprocess.run(["touch #{marker}"], timeout: 5) }

      assert_equal "executable not found: touch #{marker}", error.message
      refute_path_exists marker
    end
  end

  def test_file_descriptors_are_not_inherited
    reader, writer = IO.pipe
    inheritable = IO.for_fd(writer.fcntl(Fcntl::F_DUPFD, 200))
    inheritable.close_on_exec = false
    script = "begin; IO.for_fd(#{inheritable.fileno}, autoclose: false); print :open; " \
      "rescue Errno::EBADF; print :closed; end"

    assert_equal "open", IO.popen(ruby(script), &:read), "precondition: plain popen inherits the descriptor"
    assert_equal "closed", Subprocess.run(ruby(script), timeout: 5).stdout
  ensure
    [reader, writer, inheritable].compact.each(&:close)
  end

  def test_child_leads_its_own_process_group
    result = Subprocess.run(ruby("print Process.pid, ' ', Process.getpgrp"), timeout: 5)
    pid, pgid = result.stdout.split.map { |s| Integer(s) }

    assert_equal pid, pgid
    refute_equal Process.getpgrp, pgid
  end

  # --- executable errors ---------------------------------------------------------------------------

  def test_missing_executable_raises_loader_unavailable
    error = assert_raises(ZXingFFI::LoaderUnavailable) do
      Subprocess.run(["zxing-ffi-no-such-tool", "-v"], timeout: 5)
    end
    assert_equal "executable not found: zxing-ffi-no-such-tool", error.message

    assert_raises(ZXingFFI::LoaderUnavailable) { Subprocess.run(["/nonexistent/zxing-ffi/pdftoppm"], timeout: 5) }

    in_tmpdir do |dir|
      file = File.join(dir, "file")
      File.write(file, "")
      through_a_file = File.join(file, "pdftoppm") # ENOTDIR
      error = assert_raises(ZXingFFI::LoaderUnavailable) { Subprocess.run([through_a_file], timeout: 5) }
      assert_equal "executable not found: #{through_a_file}", error.message
    end
  end

  def test_other_spawn_failures_raise_render_error
    # A 3 MB argument exceeds ARG_MAX (macOS) and MAX_ARG_STRLEN (Linux): execve fails with E2BIG.
    error = assert_raises(ZXingFFI::RenderError) { Subprocess.run(["true", "x" * 3_000_000], timeout: 5) }

    assert_match(/\Acould not start true: Argument list too long/, error.message)
    assert_kind_of Errno::E2BIG, error.cause
  end

  def test_non_executable_file_or_directory_raises_loader_unavailable
    in_tmpdir do |dir|
      path = File.join(dir, "tool")
      File.write(path, "#!/bin/sh\necho hi\n")
      File.chmod(0o644, path)

      error = assert_raises(ZXingFFI::LoaderUnavailable) { Subprocess.run([path], timeout: 5) }
      assert_equal "executable not permitted: #{path}", error.message
      assert_raises(ZXingFFI::LoaderUnavailable) { Subprocess.run([dir], timeout: 5) }
    end
  end

  # --- validation ----------------------------------------------------------------------------------

  def test_rejects_invalid_argv
    invalid = [nil, "echo hi", [], [:echo], ["echo", 1], ["echo", nil], [Pathname("/bin/echo")],
      ["ec\0ho"], ["echo", "a\0b"], [""]]
    invalid.each do |argv|
      assert_raises(ArgumentError, argv.inspect) { Subprocess.run(argv, timeout: 5) }
    end
  end

  def test_rejects_invalid_options
    invalid = {
      timeout: [0, -1, "5", Float::NAN, Complex(1, 1)],
      max_stdout: [-1, 1.5, "10"],
      memory_limit: [0, -1, 1.5],
      stdin_data: [123, [:data]],
      env: ["A=1", [["A", "1"]]],
      stderr_limit: [nil, -1, 2.5],
      kill_grace: [nil, -0.1, Float::INFINITY, "2"]
    }
    invalid.each do |option, values|
      values.each do |value|
        options = {timeout: 5}.merge(option => value)
        assert_raises(ArgumentError, "#{option}: #{value.inspect}") { Subprocess.run(["true"], **options) }
      end
    end
  end

  # --- memory_limit --------------------------------------------------------------------------------

  def test_memory_limit_sets_rlimit_as_on_linux
    skip "memory_limit is only applied on Linux" unless Subprocess.linux?

    limit = 3 * 1024**3
    expected = [limit, Process.getrlimit(:AS).last].min
    result = Subprocess.run(ruby("print Process.getrlimit(:AS).join(' ')"), timeout: 10, memory_limit: limit)

    assert_equal "#{expected} #{expected}", result.stdout
  end

  def test_memory_limit_is_ignored_elsewhere
    skip "memory_limit is applied on Linux" if Subprocess.linux?

    # 1 MiB would keep Ruby from starting if it were applied.
    result = Subprocess.run(ruby("print Process.getrlimit(:AS).join(' ')"), timeout: 10, memory_limit: 1024**2)

    assert_predicate result, :success?
    assert_equal Process.getrlimit(:AS).join(" "), result.stdout
  end

  # --- which / linux? ------------------------------------------------------------------------------

  def test_which_finds_executables_on_path
    sh = Subprocess.which("sh")

    assert sh, "sh should be on PATH"
    assert File.absolute_path?(sh), "expected an absolute path, got #{sh}"
    assert File.executable?(sh)
    assert_nil Subprocess.which("zxing-ffi-no-such-tool")
    assert_nil Subprocess.which(nil)
    assert_nil Subprocess.which("")
  end

  def test_which_searches_path_in_order_and_skips_non_executables
    in_tmpdir do |dir|
      first = File.join(dir, "first")
      second = File.join(dir, "second")
      Dir.mkdir(first)
      Dir.mkdir(second)
      File.write(File.join(first, "zxing-ffi-tool"), "not executable")
      Dir.mkdir(File.join(first, "zxing-ffi-dir"))
      tool = write_executable(File.join(second, "zxing-ffi-tool"))

      with_env("PATH" => [first, second].join(File::PATH_SEPARATOR)) do
        assert_equal tool, Subprocess.which("zxing-ffi-tool")
        assert_nil Subprocess.which("zxing-ffi-dir")
      end
    end
  end

  def test_which_checks_paths_with_a_separator_directly
    in_tmpdir do |dir|
      tool = write_executable(File.join(dir, "tool"))
      plain = File.join(dir, "plain")
      File.write(plain, "not executable")

      assert_equal tool, Subprocess.which(tool)
      assert_nil Subprocess.which(plain)
      assert_nil Subprocess.which(dir)
      assert_nil Subprocess.which(File.join(dir, "missing"))
    end
  end

  def test_which_skips_empty_path_entries_and_expands_relative_ones
    in_tmpdir do |dir|
      write_executable(File.join(dir, "zxing-ffi-cwd-tool"))
      Dir.chdir(dir) do
        with_env("PATH" => "#{File::PATH_SEPARATOR}/nonexistent") do
          assert_nil Subprocess.which("zxing-ffi-cwd-tool")
        end
        with_env("PATH" => ".") do
          assert_equal File.join(Dir.pwd, "zxing-ffi-cwd-tool"), Subprocess.which("zxing-ffi-cwd-tool")
        end
      end
    end
  end

  def test_linux_predicate_matches_the_platform
    assert_equal RUBY_PLATFORM.include?("linux"), Subprocess.linux?
  end

  private

  # argv for a Ruby one-liner without RubyGems or the bundler RUBYOPT (starts in ~10 ms).
  # +lib: true+ puts this checkout's lib on the load path.
  def ruby(script, *args, lib: false)
    [RbConfig.ruby, "--disable=gems,rubyopt", *(lib ? ["-I", LIB] : []), "-e", script, *args]
  end

  # Calls +hook+ with the pid right after every Process.spawn made by this thread inside the block.
  def with_spawn_hook(hook)
    Process.singleton_class.prepend(SpawnHook) unless Process.singleton_class.include?(SpawnHook)
    Thread.current[:zxing_ffi_spawn_hook] = hook
    yield
  ensure
    Thread.current[:zxing_ffi_spawn_hook] = nil
  end

  def measure
    started = monotonic_now
    result = yield
    [result, monotonic_now - started]
  end

  def monotonic_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def read_pids(path)
    File.read(path).split.map { |pid| Integer(pid) }
  end

  def wait_for_pid(path, within: 5)
    deadline = monotonic_now + within
    until File.exist?(path) && File.read(path).match?(/\A\d+\n\z/)
      flunk("#{path} was not written within #{within}s") if monotonic_now > deadline
      sleep 0.01
    end
    read_pids(path).first
  end

  # Every helper thread started inside the block must be finished (joined) when the block returns.
  def assert_no_new_threads
    before = Thread.list
    yield
    leftover = Thread.list - before
    assert_empty leftover, "threads still alive: #{leftover.map(&:name).inspect}"
  end

  # Our own child: it must be dead and already reaped (not a zombie waiting for us).
  def assert_reaped(pid)
    assert_raises(Errno::ECHILD, "child #{pid} was not reaped") { Process.waitpid(pid, Process::WNOHANG) }
    assert_process_gone(pid)
  end

  # Any process: polls until it no longer exists (orphans are reaped by init/launchd shortly after dying).
  def assert_process_gone(pid, within: 3)
    deadline = monotonic_now + within
    loop do
      Process.kill(0, pid)
      flunk("process #{pid} is still running #{within}s later") if monotonic_now > deadline
      sleep 0.02
    rescue Errno::ESRCH, Errno::EPERM
      return pass
    end
  end

  def kill_quietly(pid)
    Process.kill(:KILL, pid)
  rescue Errno::ESRCH, Errno::EPERM
    nil
  end

  # Kills and reaps one of our own children, if it is still around.
  def reap_quietly(pid)
    kill_quietly(pid)
    Process.wait(pid)
  rescue Errno::ECHILD
    nil
  end

  def write_executable(path)
    File.write(path, "#!/bin/sh\nexit 0\n")
    File.chmod(0o755, path)
    path
  end

  def open_fd_count
    Dir.children("/dev/fd").size
  end
end
