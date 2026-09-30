# frozen_string_literal: true

module ZXingFFI
  module Loaders
    # Size and orientation of one page or frame, known before rendering.
    #
    # @!attribute number [Integer] 1-based
    # @!attribute width [Numeric] as displayed (after /Rotate or EXIF orientation), in +unit+
    # @!attribute height [Numeric] as displayed, in +unit+
    # @!attribute unit [Symbol] +:pt+ for PDF pages, +:px+ for raster frames
    # @!attribute rotation [Integer] PDF /Rotate or applied EXIF rotation in degrees (0 when unknown)
    # @!attribute native_ppi [Float, nil] resolution of the scan image covering the page (PDF), or the
    #   raster's resolution when recorded; nil when unknown or born-digital
    PageInfo = Data.define(:number, :width, :height, :unit, :rotation, :native_ppi)

    # A rendered page.
    #
    # @!attribute number [Integer] 1-based page/frame number
    # @!attribute image [Image] normalized 8-bit luminance image
    # @!attribute dpi [Integer, nil] render DPI (PDF) or nil for rasters
    # @!attribute scale_to_base [Float] factor mapping this image's pixels to the page's base image (1.0 for the base)
    # @!attribute metadata [Hash] what was applied, e.g. +orientation_applied:+, +aspect_corrected:+, +dpi_capped:+
    Page = Data.define(:number, :image, :dpi, :scale_to_base, :metadata)

    # Base class for loaders. Subclasses implement the class-level capability checks and {#open}.
    class Base
      class << self
        # @return [Symbol] registry name, e.g. +:poppler+
        def loader_name
          raise NotImplementedError, "#{name}.loader_name"
        end

        # Input kinds this loader can handle in principle (see {Sniffer::KINDS}).
        # @return [Array<Symbol>]
        def kinds
          raise NotImplementedError, "#{name}.kinds"
        end

        # Whether the tool/gem is present at all (memoized; see {.reset!}).
        # @return [Boolean]
        def available?
          return @available if defined?(@available)

          @available = probe
        end

        # Why {.available?} is false (or nil when available).
        # @return [String, nil]
        def unavailable_reason
          available? ? nil : (@unavailable_reason || "not available")
        end

        # Whether this loader can handle +kind+ on this machine (e.g. vips without HEIF support → false for :heif).
        # @return [Boolean]
        def supports?(kind)
          kinds.include?(kind.to_sym) && available?
        end

        # Why +kind+ is not supported although it is in {.kinds} and the loader is available (e.g. an operation
        # refused by configuration), or nil.
        # @return [String, nil]
        def unsupported_reason(kind)
          nil
        end

        # What to install to get this loader.
        # @return [String]
        def install_hint
          ""
        end

        # Tool versions and capabilities, for {ZXingFFI.diagnostics}.
        # @return [Hash]
        def diagnostics
          {available: available?, reason: unavailable_reason, kinds: available? ? kinds.select { |k| supports?(k) } : []}
        end

        # Forgets memoized availability (tests, or after installing tools at runtime).
        def reset!
          remove_instance_variable(:@available) if defined?(@available)
          @unavailable_reason = nil
        end

        private

        # Subclasses return true/false and may set @unavailable_reason.
        def probe
          raise NotImplementedError, "#{name}.probe"
        end
      end

      # @return [Config] effective configuration (global config merged with per-call overrides)
      attr_reader :config

      # @param config [Config]
      def initialize(config = ZXingFFI.config)
        @config = config
      end

      # Opens a document. Encrypted PDFs without a (correct) password raise before any rendering.
      #
      # @param source [Source] absolute path + sniffed kind
      # @param password [String, nil]
      # @return [Document]
      # @raise [PasswordRequired, IncorrectPassword, RenderError, LimitExceeded, UnsupportedInput]
      def open(source, password: nil)
        raise NotImplementedError, "#{self.class}#open"
      end
    end

    # An opened input: a sequence of pages (PDF) or frames (raster). Always {#close} it.
    class Document
      # @return [Source]
      attr_reader :source

      def initialize(source)
        @source = source
      end

      # @return [Integer]
      def page_count
        raise NotImplementedError, "#{self.class}#page_count"
      end

      # @param number [Integer] 1-based
      # @return [PageInfo]
      def page_info(number)
        raise NotImplementedError, "#{self.class}#page_info"
      end

      # Renders or decodes one page. +dpi+ is honored for PDFs and ignored for rasters.
      #
      # @param number [Integer] 1-based
      # @param dpi [Integer, Float, nil]
      # @param timeout [Numeric, nil] seconds for this render, capped by config.render_timeout (subprocess loaders;
      #   in-process loaders cannot be interrupted and ignore it)
      # @return [Page]
      def render(number, dpi: nil, timeout: nil)
        raise NotImplementedError, "#{self.class}#render"
      end

      # Releases resources (temp files, handles). Idempotent.
      def close
      end

      private

      def check_page!(number)
        return if number.is_a?(Integer) && number.between?(1, page_count)

        raise ArgumentError, "page #{number.inspect} out of range 1..#{page_count}"
      end
    end
  end
end
