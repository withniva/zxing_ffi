# frozen_string_literal: true

require "tmpdir"

module ZXingFFI
  # Locating and invoking ImageMagick safely, shared by the loader and the transformer.
  #
  # ImageMagick 7 is used through +magick+; ImageMagick 6 through +convert+ and +identify+. Inputs are always read
  # with an explicit coder prefix matching our sniffed kind (e.g. +png:/abs/path+) so ImageMagick cannot re-detect a
  # dangerous format (PDF, PS, EPS, SVG, MVG, MSL, text) from the content. Paths containing characters ImageMagick
  # interprets (+[ ] * ? { } @ %+ …) are symlinked to a safe temporary name first.
  module ImageMagick
    # Sniffed kind => ImageMagick coder. PDF and vector/text formats are deliberately absent.
    CODERS = {
      png: "png", jpeg: "jpeg", tiff: "tiff", gif: "gif", bmp: "bmp", webp: "webp",
      heif: "heic", avif: "avif", pnm: "pnm"
    }.freeze

    # Paths made only of these characters are passed to ImageMagick as they are.
    SAFE_PATH = %r{\A[A-Za-z0-9_./\- ]+\z}

    # A resolved ImageMagick installation.
    # @!attribute flavor [Symbol] +:im7+ or +:im6+
    # @!attribute convert [Array<String>] argv prefix that converts images
    # @!attribute identify [Array<String>] argv prefix that identifies images
    # @!attribute version [String, nil]
    Tool = Data.define(:flavor, :convert, :identify, :version)

    @mutex = Mutex.new

    class << self
      # The ImageMagick installation to use, or nil (memoized per configured path).
      # @return [Tool, nil]
      def tool(config = ZXingFFI.config)
        configured = config.tool_path(:magick)
        @mutex.synchronize do
          @tools ||= {}
          return @tools[configured] if @tools.key?(configured)

          @tools[configured] = detect(configured)
        end
      end

      # Forgets detected installations (tests, or after changing config.tool_paths[:magick]).
      def reset!
        @mutex.synchronize { @tools = nil }
      end

      # @return [String] why no ImageMagick is usable
      def unavailable_reason(config = ZXingFFI.config)
        configured = config.tool_path(:magick)
        configured ? "#{configured} is not a working ImageMagick 7 `magick`" : "neither `magick` (IM7) nor `convert`/`identify` (IM6) found"
      end

      # Yields a path safe to hand to ImageMagick (the original, or a symlink with a plain name).
      def with_safe_path(path)
        return yield(path) if path.match?(SAFE_PATH)

        Dir.mktmpdir("zxing_ffi_im") do |dir|
          link = File.join(dir, "input")
          File.symlink(path, link)
          yield link
        end
      end

      private

      def detect(configured)
        if configured
          version = version_of([configured, "-version"])
          return version && Tool.new(flavor: :im7, convert: [configured], identify: [configured, "identify"], version: version)
        end

        if (magick = Subprocess.which("magick")) && (version = version_of([magick, "-version"]))
          return Tool.new(flavor: :im7, convert: [magick], identify: [magick, "identify"], version: version)
        end

        convert = Subprocess.which("convert")
        identify = Subprocess.which("identify")
        if convert && identify && (version = version_of([convert, "-version"]))
          return Tool.new(flavor: :im6, convert: [convert], identify: [identify], version: version)
        end

        nil
      end

      def version_of(argv)
        status, out, = Subprocess.run(argv, timeout: 10, max_stdout: 64 * 1024)
        status.success? && out[/ImageMagick\s+(\d+\.\d+\.\d+(?:-\d+)?)/, 1]
      rescue Error
        nil
      end
    end
  end
end
