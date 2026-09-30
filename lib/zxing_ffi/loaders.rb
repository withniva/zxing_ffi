# frozen_string_literal: true

module ZXingFFI
  # Input loaders: each turns a file into pages of normalized 8-bit grayscale {Image}s.
  #
  # Loader classes are looked up by name (+:poppler+, +:vips+, +:image_magick+, +:pnm+). Every loader file can
  # be required without its external tool or gem; availability is checked at runtime.
  module Loaders
    autoload :Base, "zxing_ffi/loaders/base"
    autoload :Document, "zxing_ffi/loaders/base"
    autoload :Page, "zxing_ffi/loaders/base"
    autoload :PageInfo, "zxing_ffi/loaders/base"
    autoload :Registry, "zxing_ffi/loaders/registry"
    autoload :PopplerLoader, "zxing_ffi/loaders/poppler"
    autoload :VipsLoader, "zxing_ffi/loaders/vips"
    autoload :ImageMagickLoader, "zxing_ffi/loaders/image_magick"
    autoload :PnmLoader, "zxing_ffi/loaders/pnm"

    # Loader name => class name.
    NAMES = {
      poppler: :PopplerLoader,
      vips: :VipsLoader,
      image_magick: :ImageMagickLoader,
      pnm: :PnmLoader
    }.freeze

    class << self
      # @param name [Symbol] e.g. +:poppler+
      # @return [Class<Base>]
      # @raise [ArgumentError] for unknown names
      def fetch(name)
        const_get(NAMES.fetch(name.to_sym) { raise ArgumentError, "unknown loader #{name.inspect}; known: #{NAMES.keys.join(", ")}" })
      end

      # @return [Hash{Symbol => Class<Base>}] every loader, available or not
      def registry
        NAMES.keys.to_h { |name| [name, fetch(name)] }
      end
    end
  end
end
