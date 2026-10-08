# frozen_string_literal: true

module ZXingFFI
  module Transformers
    # Resize and rotate by piping PGM through ImageMagick.
    #
    # +-rotate+ turns clockwise and expands the canvas (ImageMagick's canvas can be 1 px larger than
    # {Geometry.rotation_canvas}; the strategy re-centers on the actual size). Upscales use +-resize+ with the
    # Catmull-Rom filter (+Catrom+); downscales use +-resize+ with its default filter.
    class ImageMagickTransformer < Base
      class << self
        def transformer_name = :image_magick

        def diagnostics
          tool = ZXingFFI::ImageMagick.tool
          tool ? super.merge(version: tool.version, flavor: tool.flavor) : super
        end

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

      def resize(image, scale)
        raise ArgumentError, "scale must be positive, got #{scale.inspect}" unless scale.is_a?(Numeric) && scale.positive?

        width = [(image.width * scale).round, 1].max
        height = [(image.height * scale).round, 1].max
        filter = (scale > 1) ? %w[-filter Catrom] : []
        pipe(image, [*filter, "-resize", "#{width}x#{height}!"], width, height)
      end

      def rotate(image, degrees, background: 255)
        raise ArgumentError, "degrees must be a finite number" unless degrees.is_a?(Numeric) && degrees.finite?

        normalized = degrees % 360
        return Image.from_pgm(image.to_pgm) if normalized.zero?

        _, width, height = Geometry.rotation_canvas(image.width, image.height, degrees)
        gray = format("#%02X%02X%02X", background, background, background)
        pipe(image, ["-background", gray, "-rotate", degrees.to_s, "+repage"], width + 4, height + 4)
      end

      private

      def pipe(image, operations, width, height)
        raise ArgumentError, "expected a :lum image, got #{image.format.inspect}" unless image.format == :lum

        tool = ZXingFFI::ImageMagick.tool(config) or raise LoaderUnavailable, ZXingFFI::ImageMagick.unavailable_reason(config)
        argv = [*tool.convert, "pgm:-", *operations, "-depth", "8", "pgm:-"]
        status, stdout, stderr = Subprocess.run(argv, timeout: config.render_timeout, stdin_data: image.to_pgm,
          max_stdout: (width + 2) * (height + 2) + 1024, memory_limit: config.subprocess_memory_limit)
        unless status.success?
          raise RenderError.new("ImageMagick transform failed (exit #{status.exitstatus}): #{stderr.lines.first&.strip}",
            stderr: stderr, exit_status: status.exitstatus)
        end

        Image.from_pgm(stdout)
      end
    end
  end
end
