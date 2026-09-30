# frozen_string_literal: true

module ZXingFFI
  module Loaders
    # Pure-Ruby loader for PNM files (P1–P6), always available.
    #
    # The file is streamed, never read whole: its header is read when the document is opened (at most
    # {HEADER_LIMIT} bytes), and {PnmDocument#render} checks +max_pixels+ against it before {Pnm.decode} reads
    # the raster in bounded chunks and nothing after it. So memory stays close to the decoded image's size
    # whatever the file holds, a huge tail included.
    class PnmLoader < Base
      # Longest header accepted, comments included (it is read in chunks of 4 KiB and more).
      HEADER_LIMIT = 1024 * 1024

      class << self
        # (see Base.loader_name)
        def loader_name = :pnm

        # (see Base.kinds)
        def kinds = [:pnm]

        # (see Base.install_hint)
        def install_hint = "PNM input needs no external tools"

        private

        def probe = true
      end

      # @return [PnmDocument]
      # @raise [UnsupportedInput] if the file does not start with a valid PNM header of at most {HEADER_LIMIT} bytes
      def open(source, password: nil)
        PnmDocument.new(source, max_pixels: config.max_pixels)
      end

      # A single-image PNM file.
      class PnmDocument < Document
        def initialize(source, max_pixels:)
          super(source)
          @max_pixels = max_pixels
          @header = read_header
        end

        # (see Document#page_count)
        def page_count = 1

        # (see Document#page_info)
        def page_info(number)
          check_page!(number)
          PageInfo.new(number: 1, width: @header.width, height: @header.height, unit: :px, rotation: 0, native_ppi: nil)
        end

        # (see Document#render)
        # @raise [LimitExceeded] before reading the raster if the header declares more than +max_pixels+
        # @raise [UnsupportedInput] if the raster is truncated or malformed
        def render(number, dpi: nil, timeout: nil)
          check_page!(number)
          check_pixels!
          decoded = File.open(source.path, "rb") { |file| ZXingFFI::Pnm.decode(file, max_pixels: @max_pixels) }
          image = Image.new(decoded.pixels, width: decoded.width, height: decoded.height)
          decoded.pixels.clear # copied into the image: free it now rather than at the next GC
          Page.new(number: 1, image: image, dpi: nil, scale_to_base: 1.0, metadata: {loader: :pnm, pnm_kind: @header.kind})
        end

        private

        def read_header
          File.open(source.path, "rb") do |file|
            reader = LimitedReader.new(file, HEADER_LIMIT)
            ZXingFFI::Pnm.read_header(reader)
          rescue UnsupportedInput
            # Reaching the limit means the header was still incomplete there (a malformed one fails earlier).
            raise unless reader.cut_short?

            raise UnsupportedInput, "PNM header longer than #{HEADER_LIMIT} bytes (long comments?) is not supported"
          end
        end

        # Checked from the header before reading the raster.
        def check_pixels!
          pixels = @header.width * @header.height
          return unless @max_pixels && pixels > @max_pixels

          raise LimitExceeded.new("#{@header.width}x#{@header.height} (#{pixels} pixels) exceeds max_pixels #{@max_pixels}",
            limit: :max_pixels, value: pixels)
        end
      end

      # Reads at most +limit+ bytes of an IO and then behaves as if at its end.
      class LimitedReader
        def initialize(io, limit)
          @io = io
          @remaining = limit
        end

        # @return [String, nil] like IO#read(length)
        def read(length)
          return nil if @remaining.zero?

          data = @io.read([length, @remaining].min)
          @remaining -= data.bytesize if data
          data
        end

        # Whether the limit hid data that the IO still holds.
        def cut_short?
          @remaining.zero? && !@io.eof?
        end
      end
      private_constant :LimitedReader
    end
  end
end
