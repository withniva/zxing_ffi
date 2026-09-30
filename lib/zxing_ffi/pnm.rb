# frozen_string_literal: true

module ZXingFFI
  # Pure-Ruby decoder for the Netpbm formats (PBM, PGM and PPM, both the ASCII "plain" variants +P1+–+P3+ and
  # the binary +P4+–+P6+) producing 8-bit luminance, plus a minimal PGM writer.
  #
  # Besides reading user files it parses the PGM that +pdftoppm -gray+ and ImageMagick's +pgm:-+ write.
  # That common case, a binary PGM with maxval 255, costs a header parse and a slice of the input
  # with no per-pixel work. Other variants are converted with C-speed primitives where Ruby has them
  # (+String#tr+ look-up tables, +unpack+/+pack+); only colour (PPM) input needs a per-pixel Ruby loop.
  #
  # Every variant except 8-bit PGM held in a String is converted in steps of 16K pixels (64 KiB of text for
  # the ASCII variants) appended to a single output String, and each step's temporaries are freed before
  # the next, so the memory needed beyond the input and the output stays under a few MB whatever the image
  # size or content. An IO is read the same way, in chunks, and not past the raster (see {decode}).
  #
  # Conversions applied by {decode}:
  # - samples are scaled to 0..255 with rounding, +(v * 255 + maxval / 2) / maxval+, so 16-bit input is
  #   scaled, never truncated; samples above maxval (invalid) are clamped to 255;
  # - PBM bits become 255 (bit 0, white) and 0 (bit 1, black);
  # - PPM pixels become zxing-cpp's luminance +(306 * r + 601 * g + 117 * b + 0x200) >> 10+ of the
  #   scaled channels.
  #
  # Header syntax follows the Netpbm reference implementation: tokens are separated by any mix of whitespace
  # (space, TAB, LF, VT, FF, CR) and +#+ comments running to the end of the line, and exactly one whitespace
  # byte ends the header (so +"255\r\n"+ leaves the LF as the first raster byte). A comment directly after
  # the last token is allowed; the line break ending it is then that byte.
  #
  # @see https://netpbm.sourceforge.net/doc/pnm.html
  module Pnm
    # A parsed PNM header.
    #
    # @!attribute [r] kind
    #   @return [Symbol] +:p1+ .. +:p6+
    # @!attribute [r] width
    #   @return [Integer]
    # @!attribute [r] height
    #   @return [Integer]
    # @!attribute [r] maxval
    #   @return [Integer] largest sample value (1..65535); always 1 for bitmaps (+P1+, +P4+)
    # @!attribute [r] offset
    #   @return [Integer] byte index at which the raster starts
    Header = Data.define(:kind, :width, :height, :maxval, :offset) do
      # @return [Integer] width × height
      def pixel_count
        width * height
      end

      # Size of a binary raster (+P4+–+P6+) in bytes; +nil+ for the ASCII variants, whose size varies.
      # @return [Integer, nil]
      def raster_bytesize
        sample_bytes = (maxval > 255) ? 2 : 1
        case kind
        when :p4 then (width + 7) / 8 * height
        when :p5 then pixel_count * sample_bytes
        when :p6 then pixel_count * 3 * sample_bytes
        end
      end
    end

    # A decoded image.
    #
    # @!attribute [r] width
    #   @return [Integer]
    # @!attribute [r] height
    #   @return [Integer]
    # @!attribute [r] pixels
    #   @return [String] BINARY, width × height bytes of 8-bit luminance, row-major
    Decoded = Data.define(:width, :height, :pixels)

    # Largest accepted width or height (libZXing takes +int+ dimensions).
    MAX_DIMENSION = 2**31 - 1
    # Largest maxval allowed by the Netpbm specification.
    MAX_MAXVAL = 65_535

    # Raised internally when an incomplete header may continue in data not read yet.
    class NeedMoreData < StandardError; end

    BINARY = Encoding::BINARY
    MAGIC = {"P1" => :p1, "P2" => :p2, "P3" => :p3, "P4" => :p4, "P5" => :p5, "P6" => :p6}.freeze
    BITMAP_KINDS = %i[p1 p4].freeze
    WHITESPACE = " \t\n\v\f\r"
    # Bytes allowed right after a header token: whitespace or the start of a comment.
    DELIMITERS = "#{WHITESPACE}#".bytes.freeze
    HASH = "#".ord
    NON_WHITESPACE = /[^ \t\n\v\f\r]/
    WHITESPACE_BYTE = /[ \t\n\v\f\r]/
    LINE_END = /[\r\n]/
    NON_DIGIT = /[^0-9]/
    LEADING_ZEROS = /\A0+(?=[0-9])/
    NONZERO_DIGIT = /[1-9]/
    NON_BIT = /[^01]/
    # Bytes other than digits and whitespace (String#count syntax).
    NOT_SAMPLE_TEXT = "^0-9 \t\n\v\f\r"
    # First read when parsing a header from an IO; doubled (up to the limit) until the header fits.
    HEADER_CHUNK = 4096
    # Longest header read from an IO, comments included: a longer one raises UnsupportedInput rather than being
    # buffered without bound (an endless comment in an untrusted stream). String input is already in memory.
    MAX_HEADER_BYTES = 1024 * 1024
    # Pixels converted per step where conversion builds Arrays (16-bit P5, P6): < 1 MiB of temporaries.
    # (Larger steps are no faster.)
    CHUNK_PIXELS = 16_384
    # Bytes per step where conversion is byte for byte (8-bit P5 read from an IO).
    BYTE_CHUNK = 256 * 1024
    # Bytes per step for P4 (16Ki pixels): whole rows when a row fits, otherwise parts of one.
    BIT_CHUNK = CHUNK_PIXELS / 8
    # Bytes of text per step for the ASCII variants.
    TEXT_CHUNK = 64 * 1024
    # Spaces that overwrite the comments of an ASCII raster, one chunk of text at a time.
    BLANKS = (" " * TEXT_CHUNK).b.freeze
    # Samples cut by chunk boundaries longer than this are shortened (see shorten_sample!).
    LONG_SAMPLE = 64
    # Output capacity reserved up front when the data has not yet shown that the header's size is real.
    PREALLOCATION_LIMIT = 64 * 1024 * 1024
    # String#tr source covering every byte, and each byte escaped for use in a tr replacement.
    TR_ALL_BYTES = "\x00-\xFF".b.freeze
    TR_CHARS = Array.new(256) { |v| ["-", "\\", "^"].include?(v.chr) ? "\\#{v.chr}".b.freeze : v.chr(BINARY).freeze }.freeze
    # String#tr replacement for "01": bit 0 is white, bit 1 is black.
    BIT_PIXELS = "\xFF\x00".b.freeze
    # zxing-cpp's RGB weights, as tables (the rounding term 0x200 is folded into BLUE).
    RED = Array.new(256) { |v| 306 * v }.freeze
    GREEN = Array.new(256) { |v| 601 * v }.freeze
    BLUE = Array.new(256) { |v| 117 * v + 0x200 }.freeze

    # Reads a raster sequentially: from the data String itself, or from the bytes buffered while the header
    # was parsed followed by the rest of an IO (read on demand, never beyond what is asked for).
    class RasterReader
      def initialize(buffer, offset, io)
        @buffer = buffer
        @position = offset
        @io = io
      end

      # @return [String] BINARY, owned by the caller (who may clear it); +size+ bytes, fewer only at the end
      #   of the data
      def read(size)
        chunk = @buffer.byteslice(@position, size)
        @position += chunk.bytesize
        return chunk if @io.nil? || chunk.bytesize == size

        while chunk.bytesize < size
          more = @io.read(size - chunk.bytesize)
          break if more.nil? || more.empty?

          more = more.b if more.frozen? || more.encoding != Encoding::BINARY
          if chunk.empty?
            chunk = more
          else
            chunk << more
            more.clear
          end
        end
        chunk
      end
    end

    private_constant :NeedMoreData, :BINARY, :MAGIC, :BITMAP_KINDS, :WHITESPACE, :DELIMITERS, :HASH,
      :NON_WHITESPACE, :WHITESPACE_BYTE, :LINE_END, :NON_DIGIT, :LEADING_ZEROS, :NONZERO_DIGIT, :NON_BIT,
      :NOT_SAMPLE_TEXT, :HEADER_CHUNK, :CHUNK_PIXELS, :BYTE_CHUNK, :BIT_CHUNK,
      :TEXT_CHUNK, :BLANKS, :LONG_SAMPLE, :PREALLOCATION_LIMIT, :TR_ALL_BYTES, :TR_CHARS, :BIT_PIXELS, :RED,
      :GREEN, :BLUE, :RasterReader

    class << self
      # Parses the header of a PNM image without looking at its raster.
      #
      # @param data [String, IO] the image bytes (any encoding; always treated as bytes), or an IO positioned
      #   at the start of the image. Only the bytes the header needs are read from an IO, and a seekable IO is
      #   moved back to where it was; +offset+ is then relative to that position.
      # @return [Header]
      # @raise [UnsupportedInput] if the data is not a PNM image (P7/PAM included) or its header is malformed
      #   or truncated
      # @example
      #   ZXingFFI::Pnm.read_header("P5\n640 480\n255\n...") # => #<data Header kind=:p5, width=640, ...>
      def read_header(data)
        return parse_header(binary(data), final: true) unless io?(data)

        position = io_position(data)
        begin
          read_io_header(data).first
        ensure
          data.seek(position) if position
        end
      end

      # Decodes a PNM image to 8-bit luminance.
      #
      # Only the first image of a multi-image file is decoded: bytes after its raster are ignored.
      #
      # @param data [String, IO] the image bytes (any encoding; always treated as bytes), or an IO positioned
      #   at the start of the image. An IO is read in bounded chunks, never all at once: the header 4 KiB at a
      #   time (doubling for long headers), then the raster, exactly up to its end for the binary variants
      #   and in 64 KiB chunks for the ASCII ones. So what follows the image is read only by the first header
      #   chunk and the last ASCII chunk, and the IO's position afterwards is unspecified.
      # @param max_pixels [Integer, nil] limit on width × height, checked against the header before any
      #   pixel data is read or converted
      # @return [Decoded]
      # @raise [UnsupportedInput] if the data is not a PNM image, or is malformed or truncated
      # @raise [LimitExceeded] if width × height exceeds +max_pixels+ (+limit: :max_pixels+)
      # @example
      #   decoded = File.open("page.pgm", "rb") { |file| ZXingFFI::Pnm.decode(file, max_pixels: 64_000_000) }
      #   decoded.pixels.bytesize == decoded.width * decoded.height # => true
      def decode(data, max_pixels: nil)
        if io?(data)
          header, buffer = read_io_header(data)
          check_max_pixels(header, max_pixels)
          pixels = luminance(buffer, header, data)
        else
          buffer = binary(data)
          header = parse_header(buffer, final: true)
          check_max_pixels(header, max_pixels)
          pixels = luminance(buffer, header, nil)
        end
        Decoded.new(width: header.width, height: header.height, pixels: pixels)
      end

      # Serializes 8-bit luminance as a binary PGM (+P5+, maxval 255).
      #
      # @param pixels [String] width × height bytes, row-major
      # @param width [Integer]
      # @param height [Integer]
      # @return [String] BINARY +"P5\n<width> <height>\n255\n"+ followed by the pixels
      # @raise [ArgumentError] if the dimensions are not positive Integers or do not match +pixels.bytesize+
      # @raise [TypeError] if +pixels+ is not a String
      def encode_pgm(pixels, width, height)
        raise TypeError, "pixels must be a String, got #{pixels.class}" unless pixels.is_a?(String)
        unless width.is_a?(Integer) && height.is_a?(Integer) && width.positive? && height.positive?
          raise ArgumentError, "width and height must be positive Integers, got #{width.inspect}x#{height.inspect}"
        end
        unless pixels.bytesize == width * height
          raise ArgumentError,
            "expected #{width * height} bytes of pixels for #{width}x#{height}, got #{pixels.bytesize}"
        end

        header = "P5\n#{width} #{height}\n255\n"
        String.new(capacity: header.bytesize + pixels.bytesize, encoding: BINARY) << header << pixels.b
      end

      private

      def io?(data)
        !data.is_a?(String) && data.respond_to?(:read)
      end

      def binary(data)
        raise TypeError, "expected PNM data as a String or an IO, got #{data.class}" unless data.is_a?(String)

        (data.encoding == BINARY) ? data : data.b
      end

      # --- Header ------------------------------------------------------------------------------------------

      # Parses the header at the start of +buffer+ (BINARY). Unless +final+, the buffer may be a prefix of the
      # data and running out of bytes raises NeedMoreData instead of UnsupportedInput.
      def parse_header(buffer, final:)
        kind = parse_magic(buffer, final)
        names = BITMAP_KINDS.include?(kind) ? %i[width height] : %i[width height maxval]
        values = {maxval: 1}
        position = 2
        names.each_with_index do |name, index|
          position = skip_separators(buffer, position) || truncated!("truncated PNM header: missing #{name}", final)
          stop = buffer.byteindex(NON_DIGIT, position) || buffer.bytesize
          malformed!("expected #{name}", buffer, position) if stop == position
          # A token must be followed by a delimiter, otherwise more digits could follow.
          if stop == buffer.bytesize
            missing = names[index + 1] || "the whitespace byte that ends the header"
            truncated!("truncated PNM header: missing #{missing}", final)
          end
          malformed!("expected whitespace after #{name}", buffer, stop) unless DELIMITERS.include?(buffer.getbyte(stop))
          values[name] = check_range(name, buffer.byteslice(position, stop - position))
          position = stop
        end
        Header.new(kind: kind, offset: raster_offset(buffer, position, final), **values)
      end

      def parse_magic(buffer, final)
        magic = buffer.byteslice(0, 2)
        truncated!("not a PNM image: no data", final) if magic.empty?
        unless magic.start_with?("P")
          raise UnsupportedInput, "not a PNM image: expected magic number P1-P6, got #{magic.inspect}"
        end
        truncated!("truncated PNM header: incomplete magic number #{magic.inspect}", final) if magic.bytesize < 2

        kind = MAGIC[magic]
        unless kind
          raise UnsupportedInput, "PAM images (P7) are not supported" if magic == "P7"
          raise UnsupportedInput, "not a PNM image: expected magic number P1-P6, got #{magic.inspect}"
        end
        separator = buffer.getbyte(2)
        truncated!("truncated PNM header: missing width", final) unless separator
        malformed!("expected whitespace after magic number #{magic}", buffer, 2) unless DELIMITERS.include?(separator)
        kind
      end

      # Position of the next token after whitespace and comments, or nil if the data ends first.
      def skip_separators(buffer, position)
        loop do
          position = buffer.byteindex(NON_WHITESPACE, position)
          return nil if position.nil?
          return position unless buffer.getbyte(position) == HASH

          position = buffer.byteindex(LINE_END, position)
          return nil if position.nil?
        end
      end

      # +position+ is at the byte after the last token: a whitespace byte or a comment whose line break then
      # ends the header.
      def raster_offset(buffer, position, final)
        return position + 1 unless buffer.getbyte(position) == HASH

        line_end = buffer.byteindex(LINE_END, position) ||
          truncated!("truncated PNM header: unterminated comment after the last header value", final)
        line_end + 1
      end

      def check_range(name, digits)
        max = (name == :maxval) ? MAX_MAXVAL : MAX_DIMENSION
        significant = digits.sub(LEADING_ZEROS, "")
        # More than 10 significant digits cannot be in range; don't build a huge Integer for them.
        value = significant.to_i if significant.bytesize <= 10
        return value if value&.between?(1, max)

        shown = (significant.bytesize > 20) ? "#{significant.byteslice(0, 20)}..." : significant
        raise UnsupportedInput, "invalid PNM header: #{name} must be 1..#{max}, got #{shown}"
      end

      def truncated!(message, final)
        raise NeedMoreData unless final

        raise UnsupportedInput, message
      end

      def malformed!(expectation, buffer, position)
        found = buffer.byteslice(position, 10)
        found = found.empty? ? "end of data" : found.inspect
        raise UnsupportedInput, "malformed PNM header: #{expectation}, got #{found}"
      end

      def check_max_pixels(header, max_pixels)
        return if max_pixels.nil? || header.pixel_count <= max_pixels

        raise LimitExceeded.new(
          "PNM image is #{header.width}x#{header.height} (#{header.pixel_count} pixels), " \
          "more than max_pixels (#{max_pixels})",
          limit: :max_pixels, value: header.pixel_count
        )
      end

      # --- IO ----------------------------------------------------------------------------------------------

      def io_position(io)
        return nil unless io.respond_to?(:pos) && io.respond_to?(:seek)

        io.pos
      rescue SystemCallError, IOError # pipes, sockets and other unseekable streams
        nil
      end

      # Reads from +io+ until the header parses. Returns the header and every byte read so far (BINARY).
      def read_io_header(io)
        buffer = String.new(encoding: BINARY)
        chunk_size = HEADER_CHUNK
        loop do
          chunk = io.read(chunk_size)
          buffer << chunk.b if chunk
          final = chunk.nil? || chunk.bytesize < chunk_size # IO#read(n) only returns less at EOF
          begin
            return [parse_header(buffer, final: final), buffer]
          rescue NeedMoreData
            if buffer.bytesize >= MAX_HEADER_BYTES
              raise UnsupportedInput, "PNM header longer than #{MAX_HEADER_BYTES} bytes (long comments?) is not supported"
            end

            chunk_size = [chunk_size * 2, MAX_HEADER_BYTES - buffer.bytesize].min
          end
        end
      end

      # --- Raster ------------------------------------------------------------------------------------------

      # Converts the raster to 8-bit luminance. For String input +io+ is nil and +buffer+ is the whole data;
      # for IO input +buffer+ holds the bytes read with the header and the rest is read from +io+ on demand.
      def luminance(buffer, header, io)
        reader = RasterReader.new(buffer, header.offset, io)
        # ASCII rasters need at least one byte per pixel, so the data bounds the output of String input.
        text_capacity = io ? PREALLOCATION_LIMIT : buffer.bytesize - header.offset
        case header.kind
        when :p1 then plain_bits(reader, header, text_capacity)
        when :p2, :p3 then plain_samples(reader, header, text_capacity)
        else
          return binary_luminance(reader, header, PREALLOCATION_LIMIT) if io

          available = buffer.bytesize - header.offset
          truncated_raster!(header.raster_bytesize, available, "bytes") if available < header.raster_bytesize
          return gray_luminance(buffer, header) if header.kind == :p5 && header.maxval <= 255

          binary_luminance(reader, header, header.pixel_count)
        end
      end

      # 8-bit PGM held in a String, the hot path: a slice of the input (shared when the raster ends the data)
      # or a single String#tr.
      def gray_luminance(buffer, header)
        raster = buffer.byteslice(header.offset, header.raster_bytesize)
        (header.maxval == 255) ? raster : raster.tr(TR_ALL_BYTES, tr_table(header.maxval))
      end

      # P4/P5/P6 in steps of whole pixels (and of whole rows for P4 when they fit). Output capacity is reserved
      # once the first step shows data, up to +capacity+.
      #
      # Each step's temporaries are released with #clear as soon as they are used: CRuby then frees their
      # buffers at once, so memory stays flat instead of accumulating garbage up to the GC's malloc limit.
      def binary_luminance(reader, header, capacity)
        step_bytes, convert = binary_step(header)
        total = header.raster_bytesize
        remaining = total
        output = nil
        while remaining.positive?
          size = [remaining, step_bytes].min
          chunk = reader.read(size)
          truncated_raster!(total, total - remaining + chunk.bytesize, "bytes") if chunk.bytesize < size
          output ||= String.new(capacity: [header.pixel_count, capacity].min, encoding: BINARY)
          convert.call(chunk, output)
          chunk.clear
          remaining -= size
        end
        output
      end

      # Bytes per step and the conversion appending one step's luminance to the output.
      def binary_step(header)
        case header.kind
        when :p4
          row_bytes = (header.width + 7) / 8
          step = (row_bytes < BIT_CHUNK) ? BIT_CHUNK / row_bytes * row_bytes : BIT_CHUNK
          [step, bits_converter(header.width, row_bytes)]
        when :p5
          scale = sample_scaler(header.maxval)
          convert = lambda do |chunk, output|
            samples = scale.call(chunk)
            output << samples
            samples.clear
          end
          [(header.maxval > 255) ? 2 * CHUNK_PIXELS : BYTE_CHUNK, convert]
        else
          scale = sample_scaler(header.maxval)
          convert = lambda do |chunk, output|
            samples = scale.call(chunk)
            append_rgb_luminance(samples, output)
            samples.clear
          end
          [((header.maxval > 255) ? 6 : 3) * CHUNK_PIXELS, convert]
        end
      end

      # Scales binary samples (8- or 16-bit) to 8-bit samples. The result is +raw+ itself (converted in
      # place) for 8-bit input, a new String for 16-bit input.
      def sample_scaler(maxval)
        if maxval == 255
          ->(raw) { raw }
        elsif maxval < 255
          table = tr_table(maxval)
          ->(raw) { raw.tr!(TR_ALL_BYTES, table) || raw }
        else
          table = scale_table(maxval, 65_536)
          lambda do |raw|
            values = raw.unpack("n*").map! { |v| table[v] }
            samples = values.pack("C*")
            values.clear
            samples
          end
        end
      end

      # Maps sample values 0...size to 0..255, clamping values above maxval.
      def scale_table(maxval, size)
        half = maxval / 2
        Array.new(size) { |v| (v > maxval) ? 255 : (v * 255 + half) / maxval }
      end

      # String#tr replacement mapping every byte through scale_table(maxval, 256).
      def tr_table(maxval)
        scale_table(maxval, 256).map { |v| TR_CHARS[v] }.join
      end

      # Appends the luminance of 8-bit RGB samples to +output+; a trailing incomplete pixel is ignored.
      def append_rgb_luminance(samples, output)
        values = samples.unpack("C*")
        pixels = Array.new(values.size / 3) do |i|
          j = i * 3
          (RED[values[j]] + GREEN[values[j + 1]] + BLUE[values[j + 2]]) >> 10
        end
        pixels.pack("C*", buffer: output)
        values.clear
        pixels.clear
      end

      # The conversion of P4 steps. Rows are padded to a byte boundary; the padding bits are dropped. A row
      # wider than a step is converted in parts, +column+ counting the bytes of it already converted.
      def bits_converter(width, row_bytes)
        return ->(chunk, output) { append_bit_pixels(chunk.unpack1("B*"), output) } if width == row_bytes * 8

        row_template = "B#{width}"
        column = 0
        lambda do |chunk, output|
          position = 0
          while position < chunk.bytesize
            size = [row_bytes - column, chunk.bytesize - position].min
            template =
              if size == row_bytes then row_template
              elsif column + size == row_bytes then "B#{width - column * 8}" # the end of a row
              else "B#{size * 8}"
              end
            append_bit_pixels(chunk.unpack1(template, offset: position), output)
            column = (column + size) % row_bytes
            position += size
          end
        end
      end

      # Appends a String of "0"/"1" as white/black pixels to +output+, consuming it.
      def append_bit_pixels(bits, output)
        bits.tr!("01", BIT_PIXELS)
        output << bits
        bits.clear
      end

      # P1: one "0" or "1" per pixel, separated by whitespace or not at all. As in a single pass over the
      # whole raster, a short raster is reported as truncated even when it also holds invalid characters.
      def plain_bits(reader, header, capacity)
        count = header.pixel_count
        output = String.new(capacity: [count, capacity].min, encoding: BINARY)
        found = 0
        invalid = nil
        each_plain_piece(reader, whole_tokens: false) do |text|
          bits = text.delete(WHITESPACE)
          text.clear
          found += bits.bytesize
          unless invalid
            wanted = (found > count) ? bits.byteslice(0, bits.bytesize - (found - count)) : bits
            if wanted.count("01") == wanted.bytesize
              append_bit_pixels(wanted, output)
            else
              invalid = wanted.byteslice(wanted.byteindex(NON_BIT), 1)
            end
          end
          bits.clear
          break if found >= count
        end
        truncated_raster!(count, found, "bits") if found < count
        raise UnsupportedInput, "malformed PNM raster: expected 0 or 1 in a P1 image, got #{invalid.inspect}" if invalid

        output
      end

      # P2/P3: whitespace-separated decimal samples. Error precedence as in plain_bits.
      def plain_samples(reader, header, capacity)
        channels = (header.kind == :p3) ? 3 : 1
        count = header.pixel_count * channels
        maxval = header.maxval
        table = scale_table(maxval, maxval + 1)
        output = String.new(capacity: [header.pixel_count, capacity].min, encoding: BINARY)
        partial = "".b # P3: scaled samples of a pixel split between two pieces
        found = 0
        invalid = nil
        each_plain_piece(reader, whole_tokens: true) do |text|
          tokens = text.split(" ")
          size = tokens.size
          unless invalid
            tokens.pop(size - (count - found)) if size > count - found # whatever follows the raster
            invalid = first_invalid_sample(text, tokens)
            unless invalid
              tokens.map! do |token|
                value = token.to_i
                (value > maxval) ? 255 : table[value]
              end
              if channels == 1
                tokens.pack("C*", buffer: output)
              else
                tokens.pack("C*", buffer: partial)
                append_rgb_luminance(partial, output) # whole pixels only
                rest = partial.byteslice(partial.bytesize / 3 * 3, 2)
                partial.clear
                partial = rest
              end
            end
          end
          text.clear
          tokens.clear
          found += size
          break if found >= count
        end
        truncated_raster!(count, found, "samples") if found < count
        raise UnsupportedInput, "malformed PNM raster: expected decimal samples, got #{invalid.inspect}" if invalid

        output
      end

      # The first 20 bytes of the first token that is not a decimal number, or nil.
      def first_invalid_sample(text, tokens)
        return nil if text.count(NOT_SAMPLE_TEXT).zero? # the usual case: digits and whitespace only

        tokens.find { |token| token.match?(NON_DIGIT) }&.byteslice(0, 20)
      end

      # Yields the ASCII raster in pieces of about TEXT_CHUNK bytes with comments blanked out (Netpbm's reader
      # skips them in the raster too). With +whole_tokens+ (samples) no token is split between two pieces.
      def each_plain_piece(reader, whole_tokens:)
        carry = "".b # the start of a token cut by the end of the previous chunk
        in_comment = false
        loop do
          text = reader.read(TEXT_CHUNK)
          last = text.bytesize < TEXT_CHUNK
          in_comment = blank_comments!(text, in_comment)
          if whole_tokens && !last
            cut = text.byterindex(WHITESPACE_BYTE)
            if cut.nil? # the chunk continues a single token
              shorten_sample!(carry << text)
              text.clear
              next
            end
            piece = text.byteslice(0, cut + 1)
            piece = carry << piece unless carry.empty?
            carry = text.byteslice(cut + 1, text.bytesize - cut - 1)
          else
            piece = carry.empty? ? text : carry << text
            carry = "".b
          end
          yield piece
          break if last
        end
      end

      # Overwrites the comments in +chunk+ with spaces, in place. A comment ends at a line break or at the end
      # of the data, so this is the same as removing it, and unlike String#gsub it allocates nothing per
      # comment (a raster may hold one per pixel). +in_comment+ tells whether the previous chunk ended inside
      # a comment; returns the same for this chunk.
      def blank_comments!(chunk, in_comment)
        start = in_comment ? 0 : chunk.byteindex("#")
        line_feed = carriage_return = -1 # the next LF and CR from +start+ on (chunk.bytesize if none)
        while start
          line_feed = chunk.byteindex("\n", start) || chunk.bytesize if line_feed < start
          carriage_return = chunk.byteindex("\r", start) || chunk.bytesize if carriage_return < start
          stop = (line_feed < carriage_return) ? line_feed : carriage_return
          chunk.bytesplice(start, stop - start, BLANKS, 0, stop - start)
          return true if stop == chunk.bytesize

          start = chunk.byteindex("#", stop)
        end
        false
      end

      # Replaces a +token+ longer than LONG_SAMPLE with a short one that plain_samples decodes the same way,
      # whatever follows it: with the same first 20 bytes (shown in error messages) and the same value, or a
      # value above 65535 if that one is (both clamp to 255). Keeps a token cut by many chunk boundaries (a
      # long run of digits, or of NUL bytes after a truncated raster) from growing with the data.
      def shorten_sample!(token)
        return if token.bytesize <= LONG_SAMPLE

        head = token.byteslice(0, 20)
        if token.match?(NON_DIGIT)
          head << "x" # invalid, whatever follows
        else
          zeros = token.byteindex(NONZERO_DIGIT) || token.bytesize - 1 # a zero keeps its last digit
          significant = token.bytesize - zeros # at most 5 digits only if +head+ is all zeros
          head << ((significant > 5) ? "9999999" : token.byteslice(zeros, significant))
        end
        token.replace(head)
      end

      def truncated_raster!(expected, got, unit)
        raise UnsupportedInput, "truncated PNM: expected #{expected} #{unit} of pixel data, got #{got}"
      end
    end
  end
end
