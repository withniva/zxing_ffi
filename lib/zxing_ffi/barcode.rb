# frozen_string_literal: true

require "json"

module ZXingFFI
  # One decoded barcode. Immutable.
  #
  # Fields filled by {ZXingFFI.read}: everything except +page+, +pass+, +dpi+ and +page_position+,
  # which the scanner adds. Predicates +mirrored?+, +inverted?+, +eci?+ and +valid?+ alias the booleans.
  #
  # @!attribute text [String] decoded text (UTF-8), per +text_mode+
  # @!attribute bytes [String] raw payload bytes (BINARY)
  # @!attribute format [Symbol] specific format, e.g. +:ean_13+, +:qr_code+
  # @!attribute symbology [Symbol] symbology family, e.g. +:ean_upc+ for +:ean_13+
  # @!attribute format_name [String] library name, e.g. "EAN-13"
  # @!attribute content_type [Symbol] +:text+, +:binary+, +:mixed+, +:gs1+, +:iso15434+, +:unknown_eci+
  # @!attribute symbology_identifier [String] e.g. "]Q1"
  # @!attribute position [Quad] corners in base-image pixels
  # @!attribute page_position [Quad, nil] PDF points from the top-left of the displayed page (PDF input only)
  # @!attribute rotation [Integer] degrees clockwise, 0..359
  # @!attribute error [Hash, nil] +{type:, message:}+ (only with +return_errors: true+)
  # @!attribute line_count [Integer]
  # @!attribute sequence [Hash, nil] structured append +{index:, size:, id:}+
  # @!attribute extra_json [String, nil] raw JSON from ZXing_Barcode_extra (see {#extra})
  # @!attribute page [Integer, nil] 1-based page, nil for {ZXingFFI.read}
  # @!attribute pass [Symbol, nil] ladder pass that produced it
  # @!attribute dpi [Integer, nil] base render DPI (PDF)
  Barcode = Data.define(
    :text, :bytes, :format, :symbology, :format_name, :content_type, :symbology_identifier,
    :position, :page_position, :rotation, :mirrored, :inverted, :eci, :valid, :error,
    :line_count, :sequence, :extra_json, :page, :pass, :dpi
  ) do
    def initialize(extra_json: nil, **fields)
      @extra_cache = {} # mutable holder: the instance itself is frozen by Data
      super
    end

    def mirrored? = mirrored

    def inverted? = inverted

    def eci? = eci

    def valid? = valid

    # Symbology-specific metadata (e.g. "ECLevel", "Version" for QR), parsed from the library's JSON
    # on first access. +{}+ when there is none.
    # @return [Hash{String => Object}]
    def extra
      @extra_cache.fetch(:value) do
        json = extra_json
        @extra_cache[:value] = (json.nil? || json.empty?) ? {}.freeze : JSON.parse(json).freeze
      end
    end

    # Center of {#position}.
    # @return [Geometry::Point]
    def center
      position.center
    end

    # JSON-friendly Hash. +bytes+ is Base64-encoded (and +bytes_encoding: "base64"+ added) when the content
    # is not text or the bytes are not valid UTF-8; quads become nested Hashes.
    # @return [Hash]
    def to_h
      h = super.except(:extra_json).merge(extra: extra, position: position&.to_h, page_position: page_position&.to_h)
      utf8 = bytes.dup.force_encoding(Encoding::UTF_8)
      if content_type == :text && utf8.valid_encoding?
        h[:bytes] = utf8
      else
        h[:bytes] = [bytes].pack("m0")
        h[:bytes_encoding] = "base64"
      end
      h
    end
  end
end
