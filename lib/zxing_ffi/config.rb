# frozen_string_literal: true

module ZXingFFI
  # Global configuration. Per-call options override these values.
  #
  # Config is read at call time: do not mutate it while a scan is running.
  #
  # @example
  #   ZXingFFI.configure do |c|
  #     c.max_pixels = 32_000_000
  #     c.pdf_loaders = %i[poppler]
  #   end
  class Config
    # Default executable names for external tools. +magick: nil+ means auto-detect
    # (+magick+ for ImageMagick 7, +convert+/+identify+ for ImageMagick 6).
    DEFAULT_TOOL_PATHS = {
      pdftoppm: "pdftoppm",
      pdfinfo: "pdfinfo",
      pdfimages: "pdfimages",
      magick: nil
    }.freeze

    # @return [String, nil] explicit path to libZXing (defaults to ENV["ZXING_LIB"])
    attr_accessor :library_path
    # @return [Array<Symbol>] PDF loaders in order of preference
    attr_accessor :pdf_loaders
    # @return [Array<Symbol>] raster loaders in order of preference
    attr_accessor :image_loaders
    # @return [Array<Symbol>] transformers (resize/rotate) in order of preference
    attr_accessor :transformers
    # @return [Integer] render DPI for born-digital PDF pages
    attr_accessor :default_dpi
    # @return [Integer] upper bound for any render DPI
    attr_accessor :max_dpi
    # @return [Integer] maximum pixels per bitmap
    attr_accessor :max_pixels
    # @return [Integer, nil] with +oversize: :downscale+, the most pixels a raster may have; larger ones still raise
    attr_accessor :max_source_pixels
    # @return [Symbol] rasters over +max_pixels+: +:raise+ ({LimitExceeded}) or +:downscale+ (the libvips loader decodes
    #   them smaller to fit; positions stay in the original's pixels)
    attr_accessor :oversize
    # @return [Integer, nil] maximum number of pages per document (nil = unlimited)
    attr_accessor :max_pages
    # @return [Numeric] seconds allowed per page render
    attr_accessor :render_timeout
    # @return [Integer] address-space limit in bytes for subprocesses (Linux only)
    attr_accessor :subprocess_memory_limit
    # @return [Hash{Symbol => String, nil}] executable names/paths for external tools
    attr_accessor :tool_paths
    # @return [Boolean] block libvips "untrusted" loaders when the installed libvips supports it
    attr_accessor :vips_block_untrusted

    def initialize
      @library_path = ENV["ZXING_LIB"]
      @pdf_loaders = %i[poppler vips]
      @image_loaders = %i[vips image_magick pnm]
      @transformers = %i[vips image_magick]
      @default_dpi = 300
      @max_dpi = 600
      @max_pixels = 64_000_000
      @max_source_pixels = 1_000_000_000
      @oversize = :raise
      @max_pages = nil
      @render_timeout = 60
      @subprocess_memory_limit = 2 * 1024**3
      @tool_paths = DEFAULT_TOOL_PATHS.dup
      @vips_block_untrusted = true
    end

    # Executable configured for +tool+, falling back to the default name.
    # @param tool [Symbol] e.g. +:pdftoppm+
    # @return [String, nil]
    def tool_path(tool)
      tool_paths.fetch(tool) { DEFAULT_TOOL_PATHS[tool] }
    end

    # A copy of this config with some attributes replaced. Unknown keys raise ArgumentError.
    # @return [Config]
    def with(**overrides)
      copy = dup
      copy.tool_paths = tool_paths.dup
      overrides.each do |key, value|
        raise ArgumentError, "unknown config key: #{key.inspect}" unless respond_to?(:"#{key}=")
        copy.public_send(:"#{key}=", value)
      end
      copy
    end

    # @return [Hash]
    def to_h
      {
        library_path: library_path,
        pdf_loaders: pdf_loaders,
        image_loaders: image_loaders,
        transformers: transformers,
        default_dpi: default_dpi,
        max_dpi: max_dpi,
        max_pixels: max_pixels,
        max_source_pixels: max_source_pixels,
        oversize: oversize,
        max_pages: max_pages,
        render_timeout: render_timeout,
        subprocess_memory_limit: subprocess_memory_limit,
        tool_paths: tool_paths,
        vips_block_untrusted: vips_block_untrusted
      }
    end
  end

  class << self
    # @return [Config] the global configuration
    def config
      @config ||= Config.new
    end

    # Yields the global configuration for modification.
    # @yieldparam config [Config]
    def configure
      yield config
      config
    end

    # Restores the default configuration (mainly for tests).
    def reset_config!
      @config = Config.new
    end
  end
end
