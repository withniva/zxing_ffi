# frozen_string_literal: true

module ZXingFFI
  # Runtime map between ZXing_BarcodeFormat values and Ruby symbols.
  #
  # Values are never hardcoded: the table is built from +ZXing_BarcodeFormatsList+ and
  # +ZXing_BarcodeFormatToString+ when first needed. Symbols derive from the library's human-readable
  # names ("EAN-13" → +:ean_13+, "QR Code" → +:qr_code+).
  module Formats
    # Library names of meta-formats (sets of formats), resolved at runtime; absent ones are skipped.
    META_NAMES = %w[All AllReadable AllCreatable AllLinear AllMatrix AllGS1 AllRetail AllIndustrial].freeze

    # One concrete format.
    # @!attribute value [Integer] ZXing_BarcodeFormat value
    # @!attribute symbol [Symbol] e.g. +:ean_13+
    # @!attribute name [String] library name, e.g. "EAN-13"
    # @!attribute symbology [Integer] value of the symbology family (e.g. EAN/UPC for EAN-13)
    Info = Data.define(:value, :symbol, :name, :symbology)

    # Immutable lookup tables built from the loaded library.
    Table = Data.define(:by_value, :by_symbol, :meta, :readable, :linear, :invalid) do
      # @return [Info, nil]
      def info(value) = by_value[value]
    end

    @mutex = Mutex.new
    @table = nil

    class << self
      # Normalizes a library name to our symbol: downcase, non-alphanumerics to "_", squeeze.
      # @param name [String]
      # @return [Symbol]
      def normalize(name)
        name.to_s.downcase.gsub(/[^a-z0-9]+/, "_").gsub(/\A_+|_+\z/, "").to_sym
      end

      # @return [Array<Symbol>] every readable concrete format
      def readable
        table.readable
      end

      # @return [Array<Symbol>] readable linear (1D) formats, from the library's AllLinear meta-format
      def linear
        table.linear
      end

      # @return [Array<Symbol>] every concrete format known to the library, readable or not
      def all
        table.by_symbol.keys
      end

      # @return [Hash{Symbol => Integer}] meta-formats (+:all+, +:all_readable+, +:all_linear+, …)
      def meta
        table.meta
      end

      # @return [Symbol] our symbol for a library value (+:unknown+ when the library has no name for it)
      def symbol_for(value)
        info_for(value).symbol
      end

      # @return [String] the library's human-readable name for a value
      def name_for(value)
        info_for(value).name
      end

      # @return [Integer] library value of a concrete or meta format symbol
      # @raise [ArgumentError] for unknown formats
      def value_for(format)
        return meta.fetch(:all_readable) if all?(format)

        values = resolve(format)
        raise ArgumentError, "#{format.inspect} is not a single format" unless values&.size == 1

        values.first
      end

      # Converts a +formats:+ option into library values for ReaderOptions_setFormats.
      #
      # Accepts symbols (+:qr_code+, +:all+, +:all_linear+), the library's own strings ("QR Code", "EAN-13",
      # "QRCode", "]Q1"), comma/pipe-separated strings, and arrays of those. +:all+ maps to AllReadable.
      #
      # @return [Array<Integer>, nil] nil for +:all+/+nil+ (keep the library default: every format)
      # @raise [ArgumentError] when a name is not a known format
      def resolve(formats)
        return nil if formats.nil? || all?(formats)

        items = Array(formats).flat_map { |f| f.is_a?(String) ? f.split(/[,|]/).map(&:strip).reject(&:empty?) : [f] }
        raise ArgumentError, "formats must not be empty" if items.empty?
        return nil if items.any? { |f| all?(f) }

        items.map { |item| resolve_one(item) }.uniq
      end

      # Concrete readable format symbols covered by a +formats:+ option (e.g. +:ean_upc+ → +[:ean_13, :ean_8, …]+).
      # @return [Array<Symbol>]
      def expand(formats)
        values = resolve(formats)
        return readable if values.nil?

        readable_set = readable
        covered = values.flat_map do |value|
          Native.take_formats { |count| Native.ZXing_BarcodeFormatsList(value, count) } || []
        end
        covered.map { |v| symbol_for(v) }.uniq.select { |s| readable_set.include?(s) }
      end

      # The subset of +formats+ that is linear, for the rotated pass.
      # @return [Array<Symbol>] empty when the selection contains no linear format
      def linear_subset(formats)
        expand(formats) & linear
      end

      # The lookup tables (built on first use; requires the native library).
      # @return [Table]
      def table
        @table || @mutex.synchronize { @table ||= build_table }
      end

      private

      def all?(format)
        (format.is_a?(Symbol) || format.is_a?(String)) && format.to_s.strip.casecmp?("all")
      end

      def info_for(value)
        table.info(value) || unknown_info(value)
      end

      def unknown_info(value)
        name = Native.take_string(Native.ZXing_BarcodeFormatToString(value)) || "Unknown"
        Info.new(value: value, symbol: normalize(name), name: name, symbology: value)
      end

      def resolve_one(item)
        case item
        when Symbol
          lookup_symbol(item) || library_value(item.to_s) || unknown_format!(item)
        when String
          lookup_symbol(normalize(item)) || library_value(item) || unknown_format!(item)
        when Integer
          return item if table.by_value.key?(item) || table.meta.value?(item)

          unknown_format!(item)
        else
          raise ArgumentError, "formats must be symbols or strings, got #{item.inspect}"
        end
      end

      def lookup_symbol(symbol)
        table.by_symbol[symbol]&.value || table.meta[symbol]
      end

      # The library's own parser also accepts "QRCode", "qrcode", "]Q1", "EAN/UPC", …
      def library_value(string)
        value = Native.ZXing_BarcodeFormatFromString(string)
        Native.last_error_message # clear the thread-local error set on failure
        (value == table.invalid) ? nil : value
      end

      def unknown_format!(item)
        raise ArgumentError, "unknown barcode format #{item.inspect}. Valid formats: #{readable.join(", ")}; " \
          "meta-formats: #{meta.keys.join(", ")}"
      end

      def build_table
        Native.load!
        # A name that cannot parse yields ZXing_BarcodeFormat_Invalid, whose value we learn instead of hardcoding it.
        invalid = Native.ZXing_BarcodeFormatFromString("\u0001not-a-barcode-format")
        Native.last_error_message

        meta = META_NAMES.each_with_object({}) do |name, h|
          value = Native.ZXing_BarcodeFormatFromString(name)
          Native.last_error_message
          next if value == invalid

          h[normalize(Native.take_string(Native.ZXing_BarcodeFormatToString(value)) || name)] = value
        end
        raise IncompatibleLibrary, "libZXing lacks the All/AllReadable meta-formats" unless meta[:all] && meta[:all_readable]

        by_value = list(meta[:all]).to_h do |value|
          name = Native.take_string(Native.ZXing_BarcodeFormatToString(value))
          [value, Info.new(value: value, symbol: normalize(name), name: name, symbology: Native.ZXing_BarcodeFormatSymbology(value))]
        end
        by_symbol = by_value.values.to_h { |info| [info.symbol, info] }
        raise IncompatibleLibrary, "format names are not unique after normalization" if by_symbol.size != by_value.size

        readable = list(meta[:all_readable]).map { |v| by_value.fetch(v).symbol }
        linear = meta[:all_linear] ? list(meta[:all_linear]).map { |v| by_value.fetch(v).symbol } & readable : []

        Table.new(
          by_value: by_value.freeze,
          by_symbol: by_symbol.freeze,
          meta: meta.freeze,
          readable: readable.freeze,
          linear: linear.freeze,
          invalid: invalid
        )
      end

      def list(filter)
        Native.take_formats { |count| Native.ZXing_BarcodeFormatsList(filter, count) } ||
          raise(IncompatibleLibrary, "ZXing_BarcodeFormatsList failed: #{Native.last_error_message}")
      end
    end
  end
end
