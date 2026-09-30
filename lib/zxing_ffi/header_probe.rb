# frozen_string_literal: true

module ZXingFFI
  # Reads raster dimensions straight from file headers, without decoding anything, for the formats
  # whose headers are simple: PNG, GIF, BMP, PNM and JPEG. The scanner checks them against +max_pixels+ before any
  # loader runs, so a small file declaring a huge image is rejected the same way whichever loader is installed
  # (ImageMagick, for one, refuses to report the size of a truncated BMP/PGM, and Ubuntu's ImageMagick policy rejects
  # large JPEG headers before we see them). Other formats return nil and are checked by the loaders themselves.
  module HeaderProbe
    # Bytes read from the start of the file.
    HEAD_SIZE = 4096

    # JPEG start-of-frame markers: every SOFn except DHT (C4), JPG (C8) and DAC (CC).
    JPEG_SOF = [0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF].freeze

    # Marker segments walked before giving up on finding a JPEG frame header.
    JPEG_MAX_SEGMENTS = 256

    class << self
      # @param path [String]
      # @param kind [Symbol] sniffed kind
      # @return [Array(Integer, Integer), nil] width and height, or nil when unknown or unreadable
      def dimensions(path, kind)
        return jpeg(path) if kind == :jpeg

        head = File.open(path, "rb") { |file| file.read(HEAD_SIZE) } || "".b
        case kind
        when :png then png(head)
        when :gif then valid(head.unpack("@6v2")) if head.bytesize >= 10
        when :bmp then bmp(head)
        when :pnm then ZXingFFI::Pnm.read_header(head).then { |header| [header.width, header.height] }
        end
      rescue UnsupportedInput, ArgumentError, TypeError, SystemCallError, EOFError
        nil
      end

      # Raises when the header declares more than +max_pixels+ pixels.
      # @raise [LimitExceeded]
      def check!(path, kind, max_pixels)
        return unless max_pixels

        width, height = dimensions(path, kind)
        return unless width && height && width * height > max_pixels

        raise LimitExceeded.new("#{File.basename(path)} declares #{width}x#{height} (#{width * height} pixels), " \
          "exceeding max_pixels #{max_pixels}", limit: :max_pixels, value: width * height)
      end

      private

      def png(head)
        return nil unless head.bytesize >= 24 && head.byteslice(12, 4) == "IHDR"

        valid(head.unpack("@16N2"))
      end

      # BITMAPCOREHEADER (12 bytes) has 16-bit sizes; later headers 32-bit, with a negative height for top-down.
      def bmp(head)
        return nil unless head.bytesize >= 26

        if head.unpack1("@14V") == 12
          valid(head.unpack("@18v2"))
        else
          width, height = head.unpack("@18l<2")
          valid([width, height.abs])
        end
      end

      # Walks the marker segments to the frame header, seeking past their data: EXIF, ICC and XMP segments (up to
      # 64 KiB each) can put it far beyond HEAD_SIZE. Stops at the first scan (SOS): a frame header must precede it.
      def jpeg(path)
        File.open(path, "rb") do |file|
          return nil unless file.read(2) == "\xFF\xD8".b

          JPEG_MAX_SEGMENTS.times do
            return nil unless file.readbyte == 0xFF

            marker = file.readbyte
            marker = file.readbyte while marker == 0xFF # fill bytes
            next if marker == 0x01 || marker.between?(0xD0, 0xD8) # TEM, RSTn, SOI: no length
            return nil if marker.zero? || marker == 0xD9 || marker == 0xDA # not a marker, EOI, or SOS first

            length = file.read(2)&.unpack1("n")
            return nil unless length && length >= 2
            return valid(file.read(5).to_s.unpack("@1n2").reverse) if JPEG_SOF.include?(marker) # height, then width

            file.seek(length - 2, IO::SEEK_CUR)
          end
          nil
        end
      end

      def valid(dimensions)
        (dimensions.all? { |value| value.is_a?(Integer) && value.positive? }) ? dimensions : nil
      end
    end
  end
end
