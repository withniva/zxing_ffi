# frozen_string_literal: true

module ZXingFFI
  module Loaders
    # Raster loader running ImageMagick in a subprocess. Never used for PDF or vector/text formats.
    #
    # Load pipeline: aspect correction on the stored axes (best effort from +identify+ resolutions), then
    # +-auto-orient -background white -alpha remove -alpha off -colorspace Gray -depth 8+ to PGM on stdout.
    # The frame's size is checked against +max_pixels+ from +identify+ before anything is decoded.
    class ImageMagickLoader < Base
      # Resolutions differing by more than this ratio are corrected.
      ASPECT_TOLERANCE = 0.05

      class << self
        # (see Base.loader_name)
        def loader_name = :image_magick

        # (see Base.kinds)
        def kinds = ZXingFFI::ImageMagick::CODERS.keys

        # (see Base.install_hint)
        def install_hint
          "install ImageMagick (brew install imagemagick / apt install imagemagick)"
        end

        # (see Base.diagnostics)
        def diagnostics
          tool = ZXingFFI::ImageMagick.tool
          tool ? super.merge(version: tool.version, flavor: tool.flavor, command: tool.convert.first) : super
        end

        # (see Base.reset!)
        def reset!
          super
          ZXingFFI::ImageMagick.reset!
        end

        private

        def probe
          return true if ZXingFFI::ImageMagick.tool

          @unavailable_reason = ZXingFFI::ImageMagick.unavailable_reason
          false
        end
      end

      def open(source, password: nil)
        tool = ZXingFFI::ImageMagick.tool(config) or raise LoaderUnavailable, ZXingFFI::ImageMagick.unavailable_reason(config)
        raise UnsupportedInput, "ImageMagick is never used for #{source.kind} input" unless self.class.kinds.include?(source.kind)

        MagickDocument.new(source, config, tool)
      end

      # A raster file; one page per frame.
      class MagickDocument < Document
        # Size and resolution (ppi, nil when unknown) of one frame, from +identify+.
        Frame = Data.define(:width, :height, :x_res, :y_res)

        def initialize(source, config, tool)
          super(source)
          @config = config
          @tool = tool
          @coder = ZXingFFI::ImageMagick::CODERS.fetch(source.kind)
          @frames = identify
          raise RenderError, "ImageMagick found no frames in #{source.name}" if @frames.empty?
        end

        # (see Document#page_count)
        def page_count = @frames.size

        # (see Document#page_info)
        def page_info(number)
          check_page!(number)
          frame = @frames[number - 1]
          width, height = corrected_size(frame)
          PageInfo.new(number: number, width: width, height: height, unit: :px, rotation: 0,
            native_ppi: [frame.x_res, frame.y_res].compact.max)
        end

        # (see Document#render)
        def render(number, dpi: nil, timeout: nil)
          check_page!(number)
          frame = @frames[number - 1]
          width, height = corrected_size(frame)
          check_pixels!(width, height)
          aspect = aspect_scale(frame)
          resample = aspect ? ["-sample", "#{(aspect[0] * 100).round(4)}%x#{(aspect[1] * 100).round(4)}%!"] : []
          stdout = ZXingFFI::ImageMagick.with_safe_path(source.path) do |path|
            run([*@tool.convert, "#{@coder}:#{path}[#{number - 1}]", *resample, "-auto-orient", "-background", "white",
              "-alpha", "remove", "-alpha", "off", "-colorspace", "Gray", "-depth", "8", "pgm:-"],
              max_stdout: (width + 2) * (height + 2) * 2 + 1024, timeout: timeout)
          end
          decoded =
            begin
              ZXingFFI::Pnm.decode(stdout, max_pixels: @config.max_pixels)
            rescue UnsupportedInput => e
              raise RenderError, "ImageMagick produced invalid PGM for #{source.name}: #{e.message}"
            end
          image = Image.new(decoded.pixels, width: decoded.width, height: decoded.height)
          Page.new(number: number, image: image, dpi: nil, scale_to_base: 1.0, metadata: {
            loader: :image_magick, aspect_corrected: aspect && [frame.x_res, frame.y_res].map { |r| r.round(1) }
          })
        end

        private

        # One line per frame: width, height, x/y resolution and units. +-ping+ reads headers only, without decoding.
        def identify
          out = ZXingFFI::ImageMagick.with_safe_path(source.path) do |path|
            run([*@tool.identify, "-ping", "-format", "%w %h %x %y %U\n", "#{@coder}:#{path}"], max_stdout: 1024 * 1024)
          end
          out.each_line.filter_map do |line|
            width, height, x_res, y_res, units = line.split
            next unless width&.match?(/\A\d+\z/) && height&.match?(/\A\d+\z/)

            scale = (units == "PixelsPerCentimeter") ? 2.54 : 1.0
            Frame.new(width: Integer(width), height: Integer(height), x_res: resolution(x_res, scale), y_res: resolution(y_res, scale))
          end
        end

        def resolution(value, scale)
          number = Float(value, exception: false)
          number&.positive? ? number * scale : nil
        end

        def aspect_scale(frame)
          x, y = frame.x_res, frame.y_res
          return nil unless x && y
          return nil if (x - y).abs / [x, y].max <= ASPECT_TOLERANCE

          (x < y) ? [y / x, 1.0] : [1.0, x / y]
        end

        def corrected_size(frame)
          hscale, vscale = aspect_scale(frame) || [1.0, 1.0]
          [(frame.width * hscale).round, (frame.height * vscale).round]
        end

        def check_pixels!(width, height)
          pixels = width * height
          return unless @config.max_pixels && pixels > @config.max_pixels

          raise LimitExceeded.new("#{width}x#{height} (#{pixels} pixels) exceeds max_pixels #{@config.max_pixels}",
            limit: :max_pixels, value: pixels)
        end

        def run(argv, max_stdout:, timeout: nil)
          status, stdout, stderr = Subprocess.run(argv, timeout: [timeout, @config.render_timeout].compact.min, max_stdout: max_stdout,
            memory_limit: @config.subprocess_memory_limit)
          return stdout if status.success?

          raise RenderError.new("ImageMagick failed on #{source.name} (exit #{status.exitstatus}): #{stderr.lines.first&.strip}",
            stderr: stderr, exit_status: status.exitstatus)
        end
      end
    end
  end
end
