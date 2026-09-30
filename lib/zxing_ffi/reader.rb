# frozen_string_literal: true

module ZXingFFI
  # Single-pass decoding of an {Image}: options → native ReaderOptions, native object lifetimes,
  # and extraction of results into Ruby objects before the native collection is freed.
  module Reader
    # Option → [ReaderOptions setter, kind]. Kinds: :bool, :byte (1..255), or an Array of allowed symbols.
    SETTERS = {
      try_harder: [:ZXing_ReaderOptions_setTryHarder, :bool],
      try_rotate: [:ZXing_ReaderOptions_setTryRotate, :bool],
      try_invert: [:ZXing_ReaderOptions_setTryInvert, :bool],
      try_downscale: [:ZXing_ReaderOptions_setTryDownscale, :bool],
      try_denoise: [:ZXing_ReaderOptions_setTryDenoise, :bool],
      pure: [:ZXing_ReaderOptions_setIsPure, :bool],
      return_errors: [:ZXing_ReaderOptions_setReturnErrors, :bool],
      validate_optional_checksum: [:ZXing_ReaderOptions_setValidateOptionalChecksum, :bool],
      binarizer: [:ZXing_ReaderOptions_setBinarizer, %i[local_average global_histogram fixed_threshold bool_cast]],
      text_mode: [:ZXing_ReaderOptions_setTextMode, %i[plain eci hri escaped hex hex_eci]],
      ean_add_on: [:ZXing_ReaderOptions_setEanAddOnSymbol, %i[ignore read require]],
      max_symbols: [:ZXing_ReaderOptions_setMaxNumberOfSymbols, :byte],
      min_line_count: [:ZXing_ReaderOptions_setMinLineCount, :byte]
    }.freeze

    # Every option {ZXingFFI.read} accepts.
    OPTION_KEYS = ([:formats] + SETTERS.keys).freeze

    # Gem defaults applied unless overridden. Everything else keeps the
    # library's default (see {ZXingFFI::LIBRARY_DEFAULTS}).
    GEM_DEFAULTS = {
      formats: :all,
      validate_optional_checksum: true,
      text_mode: :plain,
      return_errors: false
    }.freeze

    # Validated reader options, reusable across many decodes (the scanner builds one per pass).
    class Options
      # @return [Hash{Symbol => Object}] effective settings (gem defaults merged with the given options)
      attr_reader :settings
      # @return [Array<Integer>, nil] resolved ZXing_BarcodeFormat values (nil = every format)
      attr_reader :format_values

      # @param options [Hash] see {ZXingFFI.read}; +nil+ values mean "library default"
      # @param defaults [Hash] merged underneath +options+
      # @raise [ArgumentError] for unknown keys or invalid values
      # @raise [NotSupported] for +try_denoise: true+ when the library lacks it
      def initialize(options = {}, defaults = GEM_DEFAULTS)
        options = options.to_h
        unknown = options.keys - OPTION_KEYS
        raise ArgumentError, "unknown option(s) #{unknown.map(&:inspect).join(", ")}; valid: #{OPTION_KEYS.join(", ")}" if unknown.any?

        @settings = defaults.merge(options).reject { |_, value| value.nil? }
        @settings.each { |key, value| validate(key, value) unless key == :formats }
        @format_values = Formats.resolve(@settings[:formats]).freeze
        if @settings[:try_denoise] && !Native.supports?(:try_denoise)
          raise NotSupported, "try_denoise needs libZXing built with ZXING_EXPERIMENTAL_API (#{Native.library.path})"
        end
        @settings.freeze
        freeze
      end

      # @return [Options] a copy with +overrides+ applied on top
      def merge(overrides)
        return self if overrides.empty?

        Options.new(settings.merge(overrides), {})
      end

      # @return [Object] the effective value of +key+ (nil = library default)
      def [](key)
        settings[key]
      end

      # @return [Hash]
      def to_h
        settings.dup
      end

      # Applies the settings to a native ZXing_ReaderOptions*.
      # @api private
      def apply(native_options)
        settings.each do |key, value|
          next if key == :formats
          next if key == :try_denoise && !value # absent symbol + false is a no-op

          Native.public_send(SETTERS.fetch(key).first, native_options, value)
        end
        return unless format_values

        buffer = FFI::MemoryPointer.new(:int, format_values.size)
        buffer.write_array_of_int(format_values)
        Native.ZXing_ReaderOptions_setFormats(native_options, buffer, format_values.size)
      end

      private

      def validate(key, value)
        kind = SETTERS.fetch(key).last
        valid =
          case kind
          when :bool then value == true || value == false
          when :byte then value.is_a?(Integer) && value.between?(1, 255)
          else kind.include?(value)
          end
        return if valid

        expected =
          case kind
          when :bool then "true or false"
          when :byte then "an Integer in 1..255"
          else kind.map(&:inspect).join(", ")
          end
        raise ArgumentError, "invalid #{key}: #{value.inspect} (expected #{expected})"
      end
    end

    class << self
      # Decodes +image+ once with +options+ and returns every barcode the library reports.
      #
      # @param image [Image]
      # @param options [Hash, Options]
      # @param crop [Array(Integer, Integer, Integer, Integer), nil] +[left, top, width, height]+ view into the
      #   image (no copy, via ZXing_ImageView_crop); positions are then relative to the crop.
      # @return [Array<Barcode>]
      # @raise [DecodeError] when ZXing_ReadBarcodes returns NULL
      def read(image, options = {}, crop: nil)
        raise TypeError, "expected a ZXingFFI::Image, got #{image.class}" unless image.is_a?(Image)

        options = Options.new(options) unless options.is_a?(Options)
        Native.load!
        pixels = image.pointer # raises if released; keeps the buffer referenced for the whole call
        validate_crop!(image, crop) if crop

        text_mode = options[:text_mode] || LIBRARY_DEFAULTS[:text_mode]
        view = options_ptr = barcodes = nil
        # Interrupts (Thread#raise, Timeout, signals) are deferred until the native objects are freed: otherwise one
        # arriving just after a native call returns, before its result is assigned, would leak that result. The
        # decode itself cannot be interrupted anyway while it runs without the GVL.
        Thread.handle_interrupt(Object => :never) do
          view = new_view(image, pixels)
          Native.ZXing_ImageView_crop(view, *crop) if crop
          options_ptr = Native.ZXing_ReaderOptions_new
          raise DecodeError, "ZXing_ReaderOptions_new failed: #{Native.last_error_message}" if options_ptr.null?

          options.apply(options_ptr)
          barcodes = Native.ZXing_ReadBarcodes(view, options_ptr)
          if barcodes.null?
            raise DecodeError, Native.last_error_message || "ZXing_ReadBarcodes failed (no error message available)"
          end

          Array.new(Native.ZXing_Barcodes_size(barcodes)) { |i| build(Native.ZXing_Barcodes_at(barcodes, i), text_mode) }
        ensure
          Native.ZXing_Barcodes_delete(barcodes) if barcodes && !barcodes.null?
          Native.ZXing_ReaderOptions_delete(options_ptr) if options_ptr && !options_ptr.null?
          Native.ZXing_ImageView_delete(view) if view && !view.null?
        end
      end

      # The library's ReaderOptions defaults, read through the get* functions.
      # @return [Hash{Symbol => Object}]
      def library_defaults
        Native.load!
        ptr = Native.ZXing_ReaderOptions_new
        raise DecodeError, "ZXing_ReaderOptions_new failed" if ptr.null?

        begin
          defaults = {
            formats: Native.take_formats { |count| Native.ZXing_ReaderOptions_getFormats(ptr, count) }.to_a.map { |v| Formats.symbol_for(v) },
            try_harder: Native.ZXing_ReaderOptions_getTryHarder(ptr),
            try_rotate: Native.ZXing_ReaderOptions_getTryRotate(ptr),
            try_invert: Native.ZXing_ReaderOptions_getTryInvert(ptr),
            try_downscale: Native.ZXing_ReaderOptions_getTryDownscale(ptr)
          }
          defaults[:try_denoise] = Native.ZXing_ReaderOptions_getTryDenoise(ptr) if Native.supports?(:try_denoise)
          defaults.merge(
            pure: Native.ZXing_ReaderOptions_getIsPure(ptr),
            return_errors: Native.ZXing_ReaderOptions_getReturnErrors(ptr),
            validate_optional_checksum: Native.ZXing_ReaderOptions_getValidateOptionalChecksum(ptr),
            binarizer: Native.ZXing_ReaderOptions_getBinarizer(ptr),
            text_mode: Native.ZXing_ReaderOptions_getTextMode(ptr),
            ean_add_on: Native.ZXing_ReaderOptions_getEanAddOnSymbol(ptr),
            max_symbols: Native.ZXing_ReaderOptions_getMaxNumberOfSymbols(ptr),
            min_line_count: Native.ZXing_ReaderOptions_getMinLineCount(ptr)
          )
        ensure
          Native.ZXing_ReaderOptions_delete(ptr)
        end
      end

      private

      def new_view(image, pixels)
        view =
          if Native.supports?(:image_view_new_checked)
            Native.ZXing_ImageView_new_checked(pixels, image.bytesize, image.width, image.height, image.format, image.row_stride, 0)
          else
            Native.ZXing_ImageView_new(pixels, image.width, image.height, image.format, image.row_stride, 0)
          end
        raise DecodeError, "could not create an ImageView for #{image.inspect}: #{Native.last_error_message}" if view.null?

        view
      end

      def validate_crop!(image, crop)
        left, top, width, height = crop
        valid = crop.is_a?(Array) && crop.size == 4 && crop.all?(Integer) &&
          left >= 0 && top >= 0 && width.positive? && height.positive? &&
          left + width <= image.width && top + height <= image.height
        raise ArgumentError, "crop #{crop.inspect} is outside #{image.width}x#{image.height}" unless valid
      end

      # Copies every field of a (parent-owned) ZXing_Barcode* into a Ruby Barcode.
      def build(ptr, text_mode)
        format = Native.ZXing_Barcode_format(ptr)
        error_type = Native.ZXing_Barcode_errorType(ptr)
        bytes = Native.take_bytes { |len| Native.ZXing_Barcode_bytes(ptr, len) }
        Barcode.new(
          text: text(Native.take_string(Native.ZXing_Barcode_text(ptr)) || "", bytes, text_mode),
          bytes: bytes,
          format: Formats.symbol_for(format),
          symbology: Formats.symbol_for(Native.ZXing_Barcode_symbology(ptr)),
          format_name: Formats.name_for(format),
          content_type: Native.ZXing_Barcode_contentType(ptr),
          symbology_identifier: Native.take_string(Native.ZXing_Barcode_symbologyIdentifier(ptr)) || "",
          position: quad(Native.ZXing_Barcode_position(ptr)),
          page_position: nil,
          rotation: Native.barcode_rotation(ptr) % 360,
          mirrored: Native.ZXing_Barcode_isMirrored(ptr),
          inverted: Native.ZXing_Barcode_isInverted(ptr),
          eci: Native.ZXing_Barcode_hasECI(ptr),
          valid: Native.ZXing_Barcode_isValid(ptr),
          error: (error_type == :none) ? nil : {type: error_type, message: Native.take_string(Native.ZXing_Barcode_errorMsg(ptr))},
          line_count: Native.ZXing_Barcode_lineCount(ptr),
          sequence: sequence(ptr),
          extra_json: Native.take_string(Native.ZXing_Barcode_extra(ptr, nil)),
          page: nil,
          pass: nil,
          dpi: nil
        )
      end

      # ZXing_Barcode_text returns a NUL-terminated C string, so plain text of a payload containing NUL bytes is
      # cut at the first NUL. Rebuild it from the bytes the way zxing-cpp renders undeclared binary data (UTF-8 if
      # valid, else ISO-8859-1), provided the library's prefix agrees.
      def text(text, bytes, text_mode)
        return text unless text_mode == :plain && bytes.include?("\x00")

        utf8 = bytes.dup.force_encoding(Encoding::UTF_8)
        rebuilt = utf8.valid_encoding? ? utf8 : bytes.dup.force_encoding(Encoding::ISO_8859_1).encode(Encoding::UTF_8)
        rebuilt.start_with?(text) ? rebuilt : text
      end

      def quad(position)
        corners = %i[top_left top_right bottom_right bottom_left].map do |corner|
          point = position[corner]
          Geometry::Point.new(point[:x], point[:y])
        end
        Geometry::Quad.new(*corners)
      end

      # Structured append: the library reports -1/-1 outside a sequence; size 0 means "unknown count".
      def sequence(ptr)
        index = Native.ZXing_Barcode_sequenceIndex(ptr)
        size = Native.ZXing_Barcode_sequenceSize(ptr)
        return nil if index.negative? || size.negative? || size == 1

        {index: index, size: size.zero? ? nil : size, id: Native.take_string(Native.ZXing_Barcode_sequenceId(ptr))}
      end
    end
  end
end
