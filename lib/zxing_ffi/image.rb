# frozen_string_literal: true

require "ffi"

module ZXingFFI
  # A normalized pixel buffer that owns its memory.
  #
  # The bytes are copied into an +FFI::MemoryPointer+ (malloc'd, never moved by the GC), which is what the
  # decoder reads while the GVL is released. Call {#release!} to free large buffers early.
  #
  # @example
  #   image = ZXingFFI::Image.new(gray_bytes, width: 640, height: 480)
  #   ZXingFFI.read(image)
  class Image
    # Bytes per pixel of each supported pixel format.
    BYTES_PER_PIXEL = {lum: 1, lum_a: 2, rgb: 3, bgr: 3, rgba: 4, argb: 4, bgra: 4, abgr: 4}.freeze

    # Largest buffer the C API can describe (its sizes are C ints).
    MAX_BYTES = 2**31 - 1

    # @return [Integer]
    attr_reader :width, :height, :row_stride, :bytesize
    # @return [Symbol] one of {BYTES_PER_PIXEL}'s keys
    attr_reader :format

    # Decodes PGM/PNM data (a String or an IO) into an 8-bit luminance image.
    # @return [Image]
    def self.from_pgm(io_or_string, max_pixels: nil)
      decoded = Pnm.decode(io_or_string, max_pixels: max_pixels)
      new(decoded.pixels, width: decoded.width, height: decoded.height)
    end

    # @param bytes [String] pixel data, at least +row_stride * height+ bytes
    # @param width [Integer]
    # @param height [Integer]
    # @param format [Symbol] +:lum+ (default), +:lum_a+, +:rgb+, +:bgr+, +:rgba+, +:argb+, +:bgra+, +:abgr+
    # @param row_stride [Integer, nil] bytes per row (default: width × bytes per pixel)
    def initialize(bytes, width:, height:, format: :lum, row_stride: nil)
      raise ArgumentError, "unsupported pixel format #{format.inspect}" unless BYTES_PER_PIXEL.key?(format)
      raise ArgumentError, "width must be a positive Integer" unless width.is_a?(Integer) && width.positive?
      raise ArgumentError, "height must be a positive Integer" unless height.is_a?(Integer) && height.positive?

      min_stride = width * BYTES_PER_PIXEL.fetch(format)
      row_stride ||= min_stride
      raise ArgumentError, "row_stride must be an Integer >= #{min_stride}" unless row_stride.is_a?(Integer) && row_stride >= min_stride

      bytes = String.try_convert(bytes) or raise(TypeError, "bytes must be a String, got #{bytes.class}")
      size = row_stride * height
      raise ArgumentError, "image too large: #{size} bytes (max #{MAX_BYTES})" if size > MAX_BYTES
      raise ArgumentError, "expected at least #{size} bytes (row_stride #{row_stride} × height #{height}), got #{bytes.bytesize}" if bytes.bytesize < size

      @width = width
      @height = height
      @format = format
      @row_stride = row_stride
      @bytesize = size
      @pointer = FFI::MemoryPointer.new(:uint8, size, false)
      @pointer.put_bytes(0, bytes, 0, size)
    end

    # The pixel buffer. Raises once the image has been released.
    # @return [FFI::MemoryPointer]
    def pointer
      @pointer or raise Error, "#{inspect} has been released"
    end

    # Frees the pixel buffer now instead of waiting for GC. Later use of the image raises.
    # Never release an image while another thread is decoding it.
    # @return [self]
    def release!
      pointer = @pointer
      @pointer = nil
      pointer&.free
      self
    end

    # @return [Boolean]
    def released?
      @pointer.nil?
    end

    # @return [Integer] bytes per pixel
    def bytes_per_pixel
      BYTES_PER_PIXEL.fetch(format)
    end

    # A BINARY copy of the pixel buffer.
    # @return [String]
    def to_bytes
      pointer.get_bytes(0, bytesize)
    end

    # A photographic negative of a +:lum+ image (every byte v becomes 255 - v), made at C speed with String#tr.
    # Used by the inverted pass: zxing-cpp's try_invert only applies to 2D readers, so white-on-black linear codes
    # need inverted pixels.
    # @return [Image]
    def inverted
      raise ArgumentError, "inverted needs a :lum image, this one is #{format.inspect}" unless format == :lum

      Image.new(to_bytes.tr(INVERT_FROM, INVERT_TO), width: width, height: height, row_stride: row_stride)
    end

    escape = ->(byte) { ["-", "^", "\\"].include?(byte) ? "\\#{byte}".b : byte.b }
    # String#tr maps for byte inversion; tr's special characters (-, ^, \) are escaped.
    INVERT_FROM = (0..255).map { |v| escape.call(v.chr) }.join.b.freeze
    INVERT_TO = (0..255).map { |v| escape.call((255 - v).chr) }.join.b.freeze
    private_constant :INVERT_FROM, :INVERT_TO

    # PGM (P5) encoding of a +:lum+ image, e.g. for piping into an external transformer.
    # @return [String]
    def to_pgm
      raise ArgumentError, "to_pgm needs a :lum image, this one is #{format.inspect}" unless format == :lum

      rows = (row_stride == width) ? to_bytes : Array.new(height) { |y| pointer.get_bytes(y * row_stride, width) }.join
      Pnm.encode_pgm(rows, width, height)
    end

    # @return [String] e.g. "#<ZXingFFI::Image 640x480 lum>"
    def inspect
      "#<#{self.class.name} #{width}x#{height} #{format}#{" (released)" if released?}>"
    end
  end
end
