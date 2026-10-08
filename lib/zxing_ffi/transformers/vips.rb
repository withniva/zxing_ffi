# frozen_string_literal: true

module ZXingFFI
  module Transformers
    # Resize and rotate with libvips (optional ruby-vips gem).
    #
    # Quarter turns use +rot+ (exact); other angles use libvips' +rotate+, which turns clockwise about the center
    # and expands the canvas like {Geometry.rotation_canvas} (canvas sizes may differ by 1 px because libvips rounds
    # where the geometry rounds up; the strategy re-centers on the actual output size). Upscales go through
    # +affine+ with the bicubic interpolator; downscales use +resize+ with a linear kernel.
    class VipsTransformer < Base
      QUARTER_TURNS = {90 => :d90, 180 => :d180, 270 => :d270}.freeze

      class << self
        def transformer_name = :vips

        def diagnostics
          available? ? super.merge(version: ::Vips.version_string) : super
        end

        private

        def probe
          require "vips"
          true
        rescue LoadError, StandardError => e
          @unavailable_reason = "ruby-vips/libvips not loadable (#{e.class}: #{e.message.lines.first&.strip})"
          false
        end
      end

      # @raise [LoaderUnavailable] when ruby-vips/libvips cannot be loaded
      def initialize(config = ZXingFFI.config)
        super
        raise LoaderUnavailable, self.class.unavailable_reason unless self.class.available? # also requires "vips"
      end

      def resize(image, scale)
        raise ArgumentError, "scale must be positive, got #{scale.inspect}" unless scale.is_a?(Numeric) && scale.positive?

        vimage = to_vips(image)
        to_image((scale > 1) ? upscale(vimage, scale) : vimage.resize(scale, kernel: :linear))
      end

      def rotate(image, degrees, background: 255)
        raise ArgumentError, "degrees must be a finite number" unless degrees.is_a?(Numeric) && degrees.finite?

        vimage = to_vips(image)
        normalized = degrees % 360
        out =
          if normalized.zero?
            vimage
          elsif QUARTER_TURNS.key?(normalized)
            vimage.rot(QUARTER_TURNS.fetch(normalized))
          else
            vimage.rotate(degrees, background: [background])
          end
        to_image(out)
      end

      private

      # Not +resize+: its upscales sample a quarter input pixel off center, so at 2x the pixel straddling each
      # black/white edge comes out mid-gray, right at the binarizer's threshold (crisp EAN-13s in the corpus misread).
      def upscale(vimage, scale)
        width = (vimage.width * scale).round
        height = (vimage.height * scale).round
        fx = width.to_f / vimage.width
        fy = height.to_f / vimage.height
        vimage.affine([fx, 0, 0, fy], interpolate: ::Vips::Interpolate.new("bicubic"), oarea: [0, 0, width, height],
          idx: 0.5 - 0.5 / fx, idy: 0.5 - 0.5 / fy, extend: :copy)
      end

      def to_vips(image)
        raise ArgumentError, "expected a :lum image, got #{image.format.inspect}" unless image.format == :lum

        bytes = (image.row_stride == image.width) ? image.to_bytes : image.to_pgm.byteslice(-image.width * image.height..)
        ::Vips::Image.new_from_memory_copy(bytes, image.width, image.height, 1, :uchar)
      end

      def to_image(vimage)
        vimage = vimage.cast(:uchar) unless vimage.format == :uchar
        ::Vips.vips_error_clear # the pipeline runs here; drop lines left in libvips' global error buffer by earlier calls
        Image.new(vimage.write_to_memory, width: vimage.width, height: vimage.height)
      rescue ::Vips::Error => e
        raise RenderError.new("libvips transform failed: #{Loaders::VipsLoader::Pipeline.error_summary(e)}", stderr: e.message[0, 4096])
      end
    end
  end
end
