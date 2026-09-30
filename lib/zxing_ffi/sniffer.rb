# frozen_string_literal: true

module ZXingFFI
  # Identifies inputs by their magic bytes, never by file name or extension.
  #
  # @example
  #   ZXingFFI::Sniffer.sniff("upload.bin")      # => :tiff
  #   ZXingFFI::Sniffer.detect("%PDF-1.7\n...")  # => :pdf
  module Sniffer
    # Every kind {detect} and {sniff} can return.
    KINDS = %i[pdf png jpeg tiff gif bmp webp heif avif pnm].freeze
    # Number of leading bytes examined. {sniff} reads at most this many.
    HEAD_SIZE = 1024

    PNG_MAGIC = "\x89PNG\r\n\x1A\n".b.freeze
    JPEG_MAGIC = "\xFF\xD8\xFF".b.freeze
    # Classic TIFF and BigTIFF, little- and big-endian.
    TIFF_MAGICS = ["II*\0", "MM\0*", "II+\0", "MM\0+"].freeze
    GIF_MAGICS = %w[GIF87a GIF89a].freeze
    PDF_MAGIC = "%PDF-"
    # Sizes of the known BMP DIB headers (BITMAPCOREHEADER, OS/2 v2, BITMAPINFOHEADER .. BITMAPV5HEADER).
    BMP_HEADER_SIZES = [12, 16, 40, 52, 56, 64, 108, 124].freeze
    AVIF_BRANDS = %w[avif avis].freeze
    HEIF_BRANDS = %w[heic heix heim heis hevc hevx].freeze
    # Generic HEIF image / image-sequence brands: AVIF when an AVIF brand is also listed, HEIF otherwise.
    MIAF_BRANDS = %w[mif1 msf1].freeze
    # P1-P6 followed by whitespace or a comment. P7 (PAM) is not supported.
    PNM_MAGIC = /\AP[1-6][ \t\n\v\f\r#]/n
    NON_PRINTABLE = /[^\x20-\x7E]/n
    private_constant :PNG_MAGIC, :JPEG_MAGIC, :TIFF_MAGICS, :GIF_MAGICS, :PDF_MAGIC, :BMP_HEADER_SIZES,
      :AVIF_BRANDS, :HEIF_BRANDS, :MIAF_BRANDS, :PNM_MAGIC, :NON_PRINTABLE

    class << self
      # Detects the kind of data from its first bytes.
      #
      # Signatures at offset 0 are checked first. A PDF is recognized by +%PDF-+ anywhere in the first
      # {HEAD_SIZE} bytes, because PDF readers accept leading junk.
      #
      # @param head [String, nil] the first bytes of the input, in any encoding (always treated as bytes);
      #   only the first {HEAD_SIZE} bytes are examined
      # @return [Symbol, nil] one of {KINDS}, or nil if the format is not recognized
      def detect(head)
        return nil if head.nil?
        raise TypeError, "expected a String, got #{head.class}" unless head.is_a?(String)

        bytes = head.b.byteslice(0, HEAD_SIZE)
        signature_kind(bytes) || (bytes.include?(PDF_MAGIC) ? :pdf : nil)
      end

      # Detects the kind of a file or IO from its content.
      #
      # @param input [String, Pathname, IO] a path, or an IO read from its current position. At most
      #   {HEAD_SIZE} bytes are read, and a seekable IO is moved back to where it was (bytes read from a pipe
      #   stay consumed).
      # @return [Symbol] one of {KINDS}
      # @raise [UnsupportedInput] if the input is empty or its format is not recognized
      # @raise [SystemCallError] if the file cannot be read (e.g. +Errno::ENOENT+)
      # @raise [TypeError] if +input+ is neither a path nor an IO
      def sniff(input)
        head, label = read_head(input)
        raise UnsupportedInput, "empty input: #{label} contains no data" if head.empty?

        detect(head) || raise(UnsupportedInput, unrecognized_message(head, label))
      end

      private

      def signature_kind(bytes)
        if bytes.start_with?(PNG_MAGIC) then :png
        elsif bytes.start_with?(JPEG_MAGIC) then :jpeg
        elsif bytes.start_with?(*TIFF_MAGICS) then :tiff
        elsif bytes.start_with?(*GIF_MAGICS) then :gif
        elsif bmp?(bytes) then :bmp
        elsif bytes.start_with?("RIFF") && bytes.byteslice(8, 4) == "WEBP" then :webp
        elsif bytes.byteslice(4, 4) == "ftyp" then iso_bmff_kind(bytes)
        elsif bytes.match?(PNM_MAGIC) then :pnm
        end
      end

      # "BM" alone is too weak (plain text can start with it): also require a known DIB header size.
      def bmp?(bytes)
        bytes.start_with?("BM") && bytes.bytesize >= 18 &&
          BMP_HEADER_SIZES.include?(bytes.unpack1("V", offset: 14))
      end

      # HEIF and AVIF files start with an ISO-BMFF ftyp box: size (uint32 BE, 0 = to the end of the file),
      # "ftyp", major brand, minor version, then compatible brands up to the end of the box.
      def iso_bmff_kind(bytes)
        return nil if bytes.bytesize < 12

        size = bytes.unpack1("N")
        return nil if size.between?(1, 15) # 1 = 64-bit size (never used for ftyp); 2..15 can't hold the brands

        box_end = size.zero? ? bytes.bytesize : [size, bytes.bytesize].min
        compatible = (16..box_end - 4).step(4).map { |offset| bytes.byteslice(offset, 4) }
        brand_kind(bytes.byteslice(8, 4), compatible)
      end

      def brand_kind(major, compatible)
        return :avif if AVIF_BRANDS.include?(major)
        return :heif if HEIF_BRANDS.include?(major)
        return nil unless MIAF_BRANDS.include?(major)

        compatible.intersect?(AVIF_BRANDS) ? :avif : :heif
      end

      # Returns the first bytes (BINARY) and a label for messages.
      def read_head(input)
        if input.is_a?(String) || (defined?(::Pathname) && input.is_a?(::Pathname))
          path = input.to_s
          [File.open(path, "rb") { |file| file.read(HEAD_SIZE) }.to_s, path]
        elsif input.respond_to?(:read)
          [read_io_head(input), io_label(input)]
        else
          raise TypeError, "expected a path (String or Pathname) or an IO, got #{input.class}"
        end
      end

      def read_io_head(io)
        position = io_position(io)
        begin
          io.read(HEAD_SIZE).to_s.b
        ensure
          io.seek(position) if position
        end
      end

      def io_position(io)
        return nil unless io.respond_to?(:pos) && io.respond_to?(:seek)

        io.pos
      rescue SystemCallError, IOError # pipes, sockets and other unseekable streams
        nil
      end

      def io_label(io)
        path = io.path if io.respond_to?(:path)
        path ? path.to_s : io.class.to_s
      rescue IOError
        io.class.to_s
      end

      def unrecognized_message(head, label)
        "unrecognized input format: #{label} is not a PDF, PNG, JPEG, TIFF, GIF, BMP, WebP, HEIF, AVIF or " \
          "PNM file (first bytes: #{hex_dump(head)}); the format is detected from the content, not the file name"
      end

      # "25 50 44 46 |%PDF|": hex and printable ASCII of the first 16 bytes.
      def hex_dump(bytes)
        sample = bytes.byteslice(0, 16)
        "#{sample.unpack1("H*").scan(/../).join(" ")} |#{sample.gsub(NON_PRINTABLE, ".")}|"
      end
    end
  end
end
