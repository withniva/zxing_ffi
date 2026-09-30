# frozen_string_literal: true

require "test_helper"
require "stringio"

# ZXingFFI::Image (pure Ruby + FFI memory; no libZXing needed).
class ImageTest < Minitest::Test
  def test_copies_bytes_into_native_memory
    source = +"\x01\x02\x03\x04\x05\x06"
    image = ZXingFFI::Image.new(source, width: 3, height: 2)
    source.replace("\x00" * 6)

    assert_equal 3, image.width
    assert_equal 2, image.height
    assert_equal :lum, image.format
    assert_equal 3, image.row_stride
    assert_equal 6, image.bytesize
    assert_equal 1, image.bytes_per_pixel
    assert_kind_of FFI::MemoryPointer, image.pointer
    assert_equal "\x01\x02\x03\x04\x05\x06".b, image.to_bytes
    assert_equal Encoding::BINARY, image.to_bytes.encoding
  end

  def test_formats_and_default_strides
    ZXingFFI::Image::BYTES_PER_PIXEL.each do |format, bpp|
      image = ZXingFFI::Image.new("\x00".b * (4 * 3 * bpp), width: 4, height: 3, format: format)
      assert_equal 4 * bpp, image.row_stride, format
      assert_equal bpp, image.bytes_per_pixel
    end
  end

  def test_explicit_row_stride
    image = ZXingFFI::Image.new("\x00".b * 20, width: 3, height: 2, row_stride: 10)

    assert_equal 10, image.row_stride
    assert_equal 20, image.bytesize
  end

  def test_extra_bytes_are_ignored
    image = ZXingFFI::Image.new("abcdefXYZ", width: 3, height: 2)
    assert_equal "abcdef".b, image.to_bytes
  end

  def test_validation
    assert_raises(ArgumentError) { ZXingFFI::Image.new("\x00" * 5, width: 3, height: 2) }
    assert_raises(ArgumentError) { ZXingFFI::Image.new("\x00" * 6, width: 0, height: 2) }
    assert_raises(ArgumentError) { ZXingFFI::Image.new("\x00" * 6, width: 3, height: -2) }
    assert_raises(ArgumentError) { ZXingFFI::Image.new("\x00" * 6, width: 3.0, height: 2) }
    assert_raises(ArgumentError) { ZXingFFI::Image.new("\x00" * 6, width: 3, height: 2, format: :cmyk) }
    assert_raises(ArgumentError) { ZXingFFI::Image.new("\x00" * 12, width: 3, height: 2, row_stride: 2) }
    assert_raises(ArgumentError) { ZXingFFI::Image.new("\x00" * 12, width: 2, height: 2, format: :rgb, row_stride: 5) }
    assert_raises(TypeError) { ZXingFFI::Image.new(nil, width: 1, height: 1) }
    assert_raises(TypeError) { ZXingFFI::Image.new([0], width: 1, height: 1) }
  end

  def test_rejects_buffers_the_c_api_cannot_describe
    error = assert_raises(ArgumentError) { ZXingFFI::Image.new("", width: 65_536, height: 65_536) }
    assert_match(/too large/, error.message)
  end

  def test_release_frees_early_and_later_use_raises
    image = ZXingFFI::Image.new("\x00" * 4, width: 2, height: 2)

    assert_same image, image.release!
    assert image.released?
    assert_raises(ZXingFFI::Error) { image.pointer }
    assert_raises(ZXingFFI::Error) { image.to_bytes }
    image.release! # idempotent
    assert_match(/released/, image.inspect)
  end

  def test_to_pgm
    image = ZXingFFI::Image.new("\x00\x80\xFF\x10\x20\x30", width: 3, height: 2)
    assert_equal "P5\n3 2\n255\n\x00\x80\xFF\x10\x20\x30".b, image.to_pgm
  end

  def test_to_pgm_drops_row_padding
    image = ZXingFFI::Image.new("ab__cd__", width: 2, height: 2, row_stride: 4)
    assert_equal "P5\n2 2\n255\nabcd".b, image.to_pgm
  end

  def test_to_pgm_requires_lum
    image = ZXingFFI::Image.new("\x00" * 12, width: 2, height: 2, format: :rgb)
    assert_raises(ArgumentError) { image.to_pgm }
  end

  def test_from_pgm_round_trip
    original = ZXingFFI::Image.new((0..255).to_a.pack("C*"), width: 16, height: 16)
    copy = ZXingFFI::Image.from_pgm(original.to_pgm)

    assert_equal [16, 16, :lum], [copy.width, copy.height, copy.format]
    assert_equal original.to_bytes, copy.to_bytes
  end

  def test_from_pgm_accepts_io_and_enforces_max_pixels
    pgm = ZXingFFI::Image.new("\x00" * 100, width: 10, height: 10).to_pgm

    assert_equal 10, ZXingFFI::Image.from_pgm(StringIO.new(pgm)).width
    assert_raises(ZXingFFI::LimitExceeded) { ZXingFFI::Image.from_pgm(pgm, max_pixels: 99) }
  end

  def test_inverted_maps_every_byte_to_its_negative
    all = (0..255).to_a.pack("C*")
    image = ZXingFFI::Image.new(all, width: 16, height: 16)
    negative = image.inverted

    assert_equal (0..255).map { |v| 255 - v }.pack("C*"), negative.to_bytes
    assert_equal [16, 16, :lum, 16], [negative.width, negative.height, negative.format, negative.row_stride]
    assert_equal all, negative.inverted.to_bytes, "inverting twice is the identity"
    refute image.released?
  end

  def test_inverted_keeps_the_row_stride
    image = ZXingFFI::Image.new("\x00\x10__\xF0\xFF__".b, width: 2, height: 2, row_stride: 4)
    assert_equal "\xFF\xEF\xA0\xA0\x0F\x00\xA0\xA0".b, image.inverted.to_bytes
  end

  def test_inverted_requires_lum
    assert_raises(ArgumentError) { ZXingFFI::Image.new("\x00" * 12, width: 2, height: 2, format: :rgb).inverted }
  end

  def test_inspect
    assert_equal "#<ZXingFFI::Image 3x2 lum>", ZXingFFI::Image.new("\x00" * 6, width: 3, height: 2).inspect
  end
end
