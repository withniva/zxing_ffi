# frozen_string_literal: true

require_relative "zxing_ffi/version"
require_relative "zxing_ffi/errors"
require_relative "zxing_ffi/config"

# Read barcodes from images and PDFs with zxing-cpp, bound through its C API with the ffi gem.
#
# @example
#   ZXingFFI.scan("invoice.pdf") # => [#<data ZXingFFI::Barcode ...>, ...]
module ZXingFFI
  autoload :LibraryLoader, "zxing_ffi/library_loader"
  autoload :Native, "zxing_ffi/native"
  autoload :Formats, "zxing_ffi/formats"
  autoload :Image, "zxing_ffi/image"
  autoload :Reader, "zxing_ffi/reader"
  autoload :LIBRARY_DEFAULTS, "zxing_ffi/library_defaults"
  autoload :Barcode, "zxing_ffi/barcode"
  autoload :Geometry, "zxing_ffi/geometry"
  autoload :Point, "zxing_ffi/geometry"
  autoload :Quad, "zxing_ffi/geometry"
  autoload :Dedupe, "zxing_ffi/dedupe"
  autoload :Pnm, "zxing_ffi/pnm"
  autoload :Sniffer, "zxing_ffi/sniffer"
  autoload :HeaderProbe, "zxing_ffi/header_probe"
  autoload :Subprocess, "zxing_ffi/subprocess"
  autoload :ImageMagick, "zxing_ffi/image_magick"
  autoload :Dpi, "zxing_ffi/dpi"
  autoload :Source, "zxing_ffi/source"
  autoload :Loaders, "zxing_ffi/loaders"
  autoload :Transformers, "zxing_ffi/transformers"
  autoload :Strategy, "zxing_ffi/strategy"
  autoload :Scanner, "zxing_ffi/scanner"
  autoload :PageResult, "zxing_ffi/scanner"
  autoload :Diagnostics, "zxing_ffi/diagnostics"
  autoload :CLI, "zxing_ffi/cli"

  class << self
    # Scans every page or frame of +input+ and returns all barcodes.
    #
    # @param input [String, Pathname, IO, Image] a path, an IO, or a raw image
    # @return [Array<Barcode>] ordered by page, then top-to-bottom, left-to-right
    def scan(input, **options)
      Scanner.new(**options).scan(input)
    end

    # Streams per-page results. Returns an Enumerator without a block.
    #
    # @yieldparam page_result [PageResult]
    def scan_pages(input, **options, &block)
      return enum_for(:scan_pages, input, **options) unless block

      Scanner.new(**options).scan_pages(input, &block)
    end

    # Decodes a raw pixel buffer with a single pass and no pipeline.
    #
    # @param image [Image]
    # @return [Array<Barcode>]
    def read(image, **options)
      Reader.read(image, options)
    end

    # All readable barcode formats as symbols, derived from the loaded library.
    # @return [Array<Symbol>]
    def formats
      Formats.readable
    end

    # Linear (1D) readable formats, used by the rotated pass.
    # @return [Array<Symbol>]
    def linear_formats
      Formats.linear
    end

    # A Hash describing the environment: library, loaders, tools and defaults.
    # @return [Hash]
    def diagnostics
      Diagnostics.collect
    end
  end
end
