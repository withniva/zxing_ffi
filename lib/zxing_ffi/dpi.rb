# frozen_string_literal: true

module ZXingFFI
  # DPI selection and pixel-cap math for PDF pages. Pure functions.
  module Dpi
    # PDF user-space units per inch.
    POINTS_PER_INCH = 72.0

    # Native resolutions used by +dpi: :auto+ are clamped to this range.
    AUTO_RANGE = (150..600)

    # Smallest render resolution used for absurdly large declared pages (see {max_dpi_for}).
    MIN_FRACTIONAL_DPI = 0.01

    # @!attribute dpi [Integer, Float] DPI to render at (a Float only for pages too large for 1 DPI)
    # @!attribute requested [Integer, Symbol] what the caller asked for
    # @!attribute source [Symbol] +:explicit+, +:native+ (scanned page) or +:default+
    # @!attribute capped [Boolean] lowered to respect max_pixels
    Choice = Data.define(:dpi, :requested, :source, :capped)

    class << self
      # Chooses the render DPI for a page.
      #
      # @param requested [Integer, :auto, nil] +:auto+/nil: the scan's native ppi clamped to 150..600 (and max_dpi)
      #   for scanned pages, else +default_dpi+; Integers are honored subject to the pixel cap
      # @param width_pt [Numeric] displayed page width in points
      # @param height_pt [Numeric] displayed page height in points
      # @param native_ppi [Numeric, nil]
      # @return [Choice]
      # @raise [LimitExceeded] when even {MIN_FRACTIONAL_DPI} would exceed max_pixels
      def choose(requested:, width_pt:, height_pt:, native_ppi: nil, default_dpi: 300, max_dpi: 600, max_pixels: 64_000_000)
        check_size!(width_pt, height_pt)
        dpi, source =
          case requested
          when :auto, nil
            if native_ppi&.positive?
              [native_ppi.round.clamp([AUTO_RANGE.min, max_dpi].min, [AUTO_RANGE.max, max_dpi].min), :native]
            else
              [[default_dpi, max_dpi].min, :default]
            end
          when Integer
            raise ArgumentError, "dpi must be positive, got #{requested}" unless requested.positive?

            [requested, :explicit]
          else
            raise ArgumentError, "dpi must be an Integer or :auto, got #{requested.inspect}"
          end

        capped = false
        if max_pixels && pixels(width_pt, height_pt, dpi) > max_pixels
          dpi = max_dpi_for(width_pt, height_pt, max_pixels)
          capped = true
        end
        Choice.new(dpi: dpi, requested: requested || :auto, source: source, capped: capped)
      end

      # Highest DPI whose render stays within +max_pixels+: an Integer, or — for absurdly large declared pages where
      # even 1 DPI is too much — a Float with three decimals (Poppler and libvips accept fractional resolutions).
      # @raise [LimitExceeded] when not even {MIN_FRACTIONAL_DPI} fits
      def max_dpi_for(width_pt, height_pt, max_pixels)
        check_size!(width_pt, height_pt)
        exact = POINTS_PER_INCH * Math.sqrt(max_pixels.to_f / (width_pt * height_pt))
        dpi = exact.floor
        dpi -= 1 while dpi.positive? && pixels(width_pt, height_pt, dpi) > max_pixels
        return dpi if dpi >= 1

        dpi = exact.floor(3)
        dpi = (dpi - 0.001).round(3) while dpi >= MIN_FRACTIONAL_DPI && pixels(width_pt, height_pt, dpi) > max_pixels
        return dpi if dpi >= MIN_FRACTIONAL_DPI

        raise LimitExceeded.new("page of #{width_pt}x#{height_pt} pt exceeds max_pixels #{max_pixels} even at #{MIN_FRACTIONAL_DPI} DPI",
          limit: :max_pixels, value: pixels(width_pt, height_pt, MIN_FRACTIONAL_DPI))
      end

      # @raise [ArgumentError] unless both sides are finite and positive
      def check_size!(width_pt, height_pt)
        return if [width_pt, height_pt].all? { |side| side.is_a?(Numeric) && side.finite? && side.positive? }

        raise ArgumentError, "page size must be finite and positive, got #{width_pt} x #{height_pt}"
      end

      # Pixel dimensions of a page rendered at +dpi+ (rounded up, like Poppler).
      # @return [Array(Integer, Integer)]
      def dimensions(width_pt, height_pt, dpi)
        [(width_pt * dpi / POINTS_PER_INCH).ceil, (height_pt * dpi / POINTS_PER_INCH).ceil]
      end

      # @return [Integer] expected pixel count at +dpi+
      def pixels(width_pt, height_pt, dpi)
        w, h = dimensions(width_pt, height_pt, dpi)
        w * h
      end

      # DPI for the high-resolution pass: 2× the base, within max_dpi and the pixel cap.
      # @return [Integer, nil] nil when that would not exceed the base DPI
      def high_res(base_dpi, width_pt:, height_pt:, max_dpi: 600, max_pixels: 64_000_000)
        dpi = [base_dpi * 2, max_dpi].min
        dpi = [dpi, max_dpi_for(width_pt, height_pt, max_pixels)].min if max_pixels
        (dpi > base_dpi) ? dpi : nil
      end
    end
  end
end
