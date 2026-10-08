# frozen_string_literal: true

module ZXingFFI
  module Transformers
    # Base class for image transformers. Implementations must not loop over pixels in Ruby.
    #
    # Geometry contract (shared with {Geometry.rotation_canvas}): {#rotate} turns the image clockwise as
    # displayed (y axis down) about its center and expands the canvas to the rotated bounding box, filling
    # uncovered areas with +background+. {#resize} scales both axes by +scale+ (output side = round(side × scale)).
    # Upscales are bicubic (Catmull-Rom) with pixel centers aligned: output pixel x samples the input at
    # (x + 0.5) / f - 0.5, f being output side / input side. Replicating pixels would keep the aliasing of codes
    # rasterized at 1-2 px per module, which the high_res upscale is there to resolve.
    class Base
      class << self
        # @return [Symbol] registry name
        def transformer_name
          raise NotImplementedError, "#{name}.transformer_name"
        end

        # @return [Boolean] memoized
        def available?
          return @available if defined?(@available)

          @available = probe
        end

        # @return [String, nil]
        def unavailable_reason
          available? ? nil : (@unavailable_reason || "not available")
        end

        # @return [Hash]
        def diagnostics
          {available: available?, reason: unavailable_reason}
        end

        def reset!
          remove_instance_variable(:@available) if defined?(@available)
          @unavailable_reason = nil
        end

        private

        def probe
          raise NotImplementedError, "#{name}.probe"
        end
      end

      # @return [Config]
      attr_reader :config

      def initialize(config = ZXingFFI.config)
        @config = config
      end

      # @param image [Image] +:lum+ image
      # @param scale [Numeric] > 0
      # @return [Image] new +:lum+ image
      def resize(image, scale)
        raise NotImplementedError, "#{self.class}#resize"
      end

      # @param image [Image] +:lum+ image
      # @param degrees [Numeric] clockwise
      # @param background [Integer] gray level for uncovered pixels
      # @return [Image] new +:lum+ image with an expanded canvas
      def rotate(image, degrees, background: 255)
        raise NotImplementedError, "#{self.class}#rotate"
      end
    end
  end
end
