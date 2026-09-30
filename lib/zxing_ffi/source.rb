# frozen_string_literal: true

require "tempfile"

module ZXingFFI
  # A scan input normalized to an absolute file path plus its sniffed kind.
  #
  # Paths are made absolute so a leading "-" can never be read as a CLI option. IO inputs are spooled to a
  # 0600 Tempfile that {.open} always removes.
  class Source
    # @return [String] absolute path
    attr_reader :path
    # @return [Symbol] sniffed kind (see {Sniffer::KINDS})
    attr_reader :kind
    # @return [String, nil] a display name (original path, or the IO's path if it has one)
    attr_reader :name

    # Yields a Source for +input+ and cleans up any temp file afterwards.
    #
    # @param input [String, Pathname, IO, #read] a path or a readable IO (read from its current position)
    # @yieldparam source [Source]
    # @raise [UnsupportedInput] for unknown file types or unsupported input objects
    def self.open(input)
      tempfile = nil
      path, name =
        # Pathname responds to #read too, so check it before the IO branch (it must not be spooled).
        if input.is_a?(String) || (defined?(::Pathname) && input.is_a?(::Pathname)) || (input.respond_to?(:to_path) && !input.respond_to?(:read))
          full = File.expand_path(input.respond_to?(:to_path) ? input.to_path : input)
          raise Errno::ENOENT, full unless File.file?(full)

          [full, input.to_s]
        elsif input.respond_to?(:read)
          tempfile = spool(input)
          [tempfile.path, (input.respond_to?(:path) ? input.path : nil)]
        else
          raise UnsupportedInput, "expected a path, an IO or a ZXingFFI::Image, got #{input.class}"
        end
      yield new(path, Sniffer.sniff(path), name)
    ensure
      if tempfile
        tempfile.close
        File.unlink(tempfile.path) if File.exist?(tempfile.path)
      end
    end

    # Copies an IO into a private temp file.
    # @return [File] closed-for-writing temp file (caller removes it)
    def self.spool(io)
      file = Tempfile.create(["zxing_ffi", ".input"], binmode: true) # created 0600
      IO.copy_stream(io, file)
      file.flush
      file
    rescue
      if file
        file.close
        File.unlink(file.path) if File.exist?(file.path)
      end
      raise
    end

    def initialize(path, kind, name = nil)
      @path = path
      @kind = kind
      @name = name || path
    end

    # @return [Integer] file size in bytes
    def size
      File.size(path)
    end

    # @return [String]
    def inspect
      "#<#{self.class.name} #{kind} #{name}>"
    end
  end
end
