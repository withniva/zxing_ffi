# frozen_string_literal: true

module ZXingFFI
  # Image transformers used by the scale and rotate passes. Pixel loops never run in Ruby.
  module Transformers
    autoload :Base, "zxing_ffi/transformers/base"
    autoload :VipsTransformer, "zxing_ffi/transformers/vips"
    autoload :ImageMagickTransformer, "zxing_ffi/transformers/image_magick"

    # Transformer name => class name.
    NAMES = {vips: :VipsTransformer, image_magick: :ImageMagickTransformer}.freeze

    class << self
      # @return [Class<Base>]
      # @raise [ArgumentError] for unknown names
      def fetch(name)
        const_get(NAMES.fetch(name.to_sym) { raise ArgumentError, "unknown transformer #{name.inspect}; known: #{NAMES.keys.join(", ")}" })
      end

      # @return [Hash{Symbol => Class<Base>}]
      def registry
        NAMES.keys.to_h { |name| [name, fetch(name)] }
      end

      # First available transformer in +order+ (default: config.transformers), or nil.
      # @return [Base, nil] an instance
      def first_available(order = ZXingFFI.config.transformers, config: ZXingFFI.config)
        order.each do |name|
          klass = fetch(name)
          return klass.new(config) if klass.available?
        end
        nil
      end
    end
  end
end
