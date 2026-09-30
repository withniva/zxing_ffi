# frozen_string_literal: true

require "test_helper"
require "stringio"

class PnmTest < Minitest::Test
  Pnm = ZXingFFI::Pnm

  # zxing-cpp's RGB → luminance formula.
  def lum(red, green, blue)
    (306 * red + 601 * green + 117 * blue + 0x200) >> 10
  end

  # The documented sample scaling.
  def scale(value, maxval)
    (value * 255 + maxval / 2) / maxval
  end

  def pgm(width, height, pixels, maxval: 255)
    "P5\n#{width} #{height}\n#{maxval}\n".b + pixels.b
  end

  def decode_bytes(data, **options)
    Pnm.decode(data, **options).pixels.bytes
  end

  def assert_unsupported(data, message)
    error = assert_raises(ZXingFFI::UnsupportedInput) { Pnm.decode(data) }
    assert_match message, error.message
    error
  end

  # --- Header: basics ------------------------------------------------------------------------------------

  def test_read_header_p5
    header = Pnm.read_header("P5\n640 480\n255\n")

    assert_equal Pnm::Header.new(kind: :p5, width: 640, height: 480, maxval: 255, offset: 15), header
  end

  def test_read_header_every_kind
    {
      "P1\n3 2\n" => [:p1, 1],
      "P2\n3 2\n15\n" => [:p2, 15],
      "P3\n3 2\n255\n" => [:p3, 255],
      "P4\n3 2\n" => [:p4, 1],
      "P5\n3 2\n65535\n" => [:p5, 65_535],
      "P6\n3 2\n1023\n" => [:p6, 1023]
    }.each do |data, (kind, maxval)|
      header = Pnm.read_header(data)
      assert_equal [kind, 3, 2, maxval, data.bytesize], [header.kind, header.width, header.height, header.maxval, header.offset], data.inspect
    end
  end

  def test_read_header_does_not_need_the_raster
    assert_equal 1_000_000, Pnm.read_header("P5 1000 1000 255\n").pixel_count
  end

  def test_header_pixel_count_and_raster_bytesize
    assert_equal 30, Pnm.read_header("P5 6 5 255\n").pixel_count
    assert_equal 30, Pnm.read_header("P5 6 5 255\n").raster_bytesize
    assert_equal 60, Pnm.read_header("P5 6 5 256\n").raster_bytesize
    assert_equal 90, Pnm.read_header("P6 6 5 255\n").raster_bytesize
    assert_equal 180, Pnm.read_header("P6 6 5 65535\n").raster_bytesize
    assert_equal 5, Pnm.read_header("P4 6 5\n").raster_bytesize
    assert_equal 10, Pnm.read_header("P4 9 5\n").raster_bytesize
    assert_equal 5, Pnm.read_header("P4 8 5\n").raster_bytesize
    %w[P1 P2 P3].each do |magic|
      assert_nil Pnm.read_header("#{magic} 6 5 255\n").raster_bytesize, magic
    end
  end

  def test_headers_and_results_are_immutable_values
    header = Pnm.read_header("P5 2 2 255\n")

    assert_predicate header, :frozen?
    assert_equal header, Pnm.read_header("P5\n2\t2\n255 ")
    assert_predicate Pnm.decode("P5 1 1 255\n\x00".b), :frozen?
  end

  # --- Header: comments and whitespace --------------------------------------------------------------------

  def test_comments_in_every_legal_position
    [
      "P5# right after the magic\n3 2 255\n",
      "P5\n# after the magic's newline\n3 2 255\n",
      "P5 3# after the width\n2 255\n",
      "P5 3 # after a space\n 2 255\n",
      "P5 3 2# after the height\n255\n",
      "P5 3 2\n#\n#\n# several, one empty\n255\n",
      "P5 3 2 255# right after maxval: its newline ends the header\n",
      "P5 3 2 255#\n",
      "P5\n#comment with P6 12 34 # and hashes\n3 2 255\n"
    ].each do |text|
      header = Pnm.read_header(text)
      assert_equal [:p5, 3, 2, 255], [header.kind, header.width, header.height, header.maxval], text.inspect
      assert_equal text.bytesize, header.offset, text.inspect
    end
  end

  def test_comment_ends_at_carriage_return
    text = "P5 3# comment\r2 255# another\r"
    header = Pnm.read_header(text)

    assert_equal [3, 2, 255, text.bytesize], [header.width, header.height, header.maxval, header.offset]
  end

  def test_comment_terminates_a_token_like_libnetpbm
    header = Pnm.read_header("P5 12#comment\n34 255\n")

    assert_equal [12, 34], [header.width, header.height]
  end

  def test_comment_after_the_delimiting_whitespace_is_raster_data
    data = "P5 2 1 255\n# ".b
    header = Pnm.read_header(data)

    assert_equal 11, header.offset
    assert_equal "# ".bytes, decode_bytes(data)
  end

  def test_arbitrary_whitespace_between_tokens
    ["P5\r\n3\r\n2\r\n255\n", "P5\t3\t2\t255\n", "P5   3     2  255\n", "P5\v3\f2\r255\t",
      "P5 \t\r\n\v\f3 \n\n 2\t\t255 "].each do |text|
      header = Pnm.read_header(text)
      assert_equal [3, 2, 255, text.bytesize], [header.width, header.height, header.maxval, header.offset], text.inspect
    end
  end

  def test_exactly_one_whitespace_byte_ends_the_header
    assert_equal "\n\x10".b.bytes, decode_bytes("P5\n2 1\n255\n\n\x10".b)
    # CRLF after maxval: CR is the delimiter, LF is the first pixel.
    assert_equal "\n\x10".b.bytes, decode_bytes("P5\r\n2 1\r\n255\r\n\x10\x20".b)
    assert_equal 13, Pnm.read_header("P5\r\n2 1\r\n255\r\n").offset
    assert_equal [32, 9], decode_bytes("P5 2 1 255\t \t".b)
  end

  def test_leading_zeros
    header = Pnm.read_header("P5 0003 0000000000000000000000002 00255\n")

    assert_equal [3, 2, 255], [header.width, header.height, header.maxval]
  end

  def test_dimension_and_maxval_bounds
    assert_equal 1, Pnm.read_header("P5 1 1 1\n").maxval
    assert_equal 65_535, Pnm.read_header("P5 1 1 65535\n").maxval
    assert_equal Pnm::MAX_DIMENSION, Pnm.read_header("P5 #{2**31 - 1} 1 255\n").width
    assert_equal Pnm::MAX_DIMENSION, Pnm.read_header("P4 1 #{2**31 - 1}\n").height
  end

  def test_header_parsing_ignores_the_string_encoding
    data = "P5\n# caf\xC3\xA9 \xFF\n2 1\n255\n\xFF\x80".dup.force_encoding(Encoding::UTF_8)
    refute_predicate data, :valid_encoding?

    assert_equal 2, Pnm.read_header(data).width
    decoded = Pnm.decode(data)
    assert_equal [255, 128], decoded.pixels.bytes
    assert_equal Encoding::BINARY, decoded.pixels.encoding
    assert_equal Encoding::UTF_8, data.encoding, "the input must not be modified"
  end

  def test_frozen_input
    data = pgm(2, 1, "\x01\x02").freeze

    assert_equal [1, 2], decode_bytes(data)
  end

  # --- Header: errors -------------------------------------------------------------------------------------

  def test_empty_data
    assert_unsupported "", /\Anot a PNM image: no data\z/
  end

  def test_not_pnm_magic
    ["GIF89a", "\x89PNG\r\n\x1A\n", "%PDF-1.7", "p5 1 1 255\n", "P0 1 1 255\n", "P8 1 1 255\n", "P9\n",
      "PF\n1 1\n-1.0\n", "Pf\n1 1\n-1.0\n", "X", "\x00"].each do |data|
      error = assert_unsupported(data.b, /\Anot a PNM image: expected magic number P1-P6, got /)
      assert_includes error.message, data.b.byteslice(0, 2).inspect
    end
  end

  def test_pam_is_rejected
    assert_unsupported "P7\nWIDTH 1\nHEIGHT 1\nDEPTH 1\nMAXVAL 255\nTUPLTYPE GRAYSCALE\nENDHDR\n\x00", /PAM images \(P7\) are not supported/
  end

  def test_magic_must_be_followed_by_whitespace
    error = assert_unsupported("P5640 480 255\n", /malformed PNM header: expected whitespace after magic number P5/)
    assert_includes error.message, '"640 480 25"'
  end

  def test_garbage_where_a_number_is_expected
    {
      "P5 abc 2 255\n" => 'expected width, got "abc 2 255\n"',
      "P5 -2 2 255\n" => 'expected width, got "-2 2 255\n"',
      "P5 +2 2 255\n" => 'expected width, got "+2 2 255\n"',
      "P5 2 x 255\n" => 'expected height, got "x 255\n"',
      "P5 2 2 ff\n" => 'expected maxval, got "ff\n"',
      "P5 2 2 -255\n" => 'expected maxval, got "-255\n"',
      "P5 \x00 2 255\n" => 'expected width, got "\x00 2 255\n"',
      "P5 2.0 2 255\n" => 'expected whitespace after width, got ".0 2 255\n"',
      "P5 640x480 255\n" => 'expected whitespace after width, got "x480 255\n"',
      "P5 2 2e1 255\n" => 'expected whitespace after height, got "e1 255\n"',
      "P5 2 2 255x\x00\x00" => 'expected whitespace after maxval, got "x\x00\x00"',
      "P5 2 2 255\x00\x00\x00\x00" => 'expected whitespace after maxval, got "\x00\x00\x00\x00"',
      "P4 8 1x\x00" => 'expected whitespace after height, got "x\x00"'
    }.each do |data, message|
      error = assert_raises(ZXingFFI::UnsupportedInput, data.inspect) { Pnm.read_header(data) }
      assert_equal "malformed PNM header: #{message}", error.message, data.inspect
    end
  end

  def test_invalid_values
    {
      "P5 0 2 255\n" => "width must be 1..2147483647, got 0",
      "P5 2 0 255\n" => "height must be 1..2147483647, got 0",
      "P5 2 2 0\n" => "maxval must be 1..65535, got 0",
      "P5 2 2 65536\n" => "maxval must be 1..65535, got 65536",
      "P5 2 2 00000000000000000065536\n" => "maxval must be 1..65535, got 65536",
      "P5 2147483648 2 255\n" => "width must be 1..2147483647, got 2147483648",
      "P4 2 99999999999\n" => "height must be 1..2147483647, got 99999999999",
      "P5 000 2 255\n" => "width must be 1..2147483647, got 0",
      "P5 #{"9" * 5000} 2 255\n" => "width must be 1..2147483647, got #{"9" * 20}..."
    }.each do |data, message|
      error = assert_raises(ZXingFFI::UnsupportedInput, data[0, 40].inspect) { Pnm.read_header(data) }
      assert_equal "invalid PNM header: #{message}", error.message
    end
  end

  def test_truncated_header_messages
    {
      "P" => 'truncated PNM header: incomplete magic number "P"',
      "P5" => "truncated PNM header: missing width",
      "P5\n" => "truncated PNM header: missing width",
      "P5\n# a comment" => "truncated PNM header: missing width",
      "P5\n64" => "truncated PNM header: missing height",
      "P5\n64 " => "truncated PNM header: missing height",
      "P5\n64 48" => "truncated PNM header: missing maxval",
      "P5\n64 48\n" => "truncated PNM header: missing maxval",
      "P5\n64 48\n255" => "truncated PNM header: missing the whitespace byte that ends the header",
      "P5\n64 48\n255# no line break" => "truncated PNM header: unterminated comment after the last header value",
      "P4\n64" => "truncated PNM header: missing height",
      "P4\n64 48" => "truncated PNM header: missing the whitespace byte that ends the header",
      "P1 2 2" => "truncated PNM header: missing the whitespace byte that ends the header"
    }.each do |data, message|
      error = assert_raises(ZXingFFI::UnsupportedInput, data.inspect) { Pnm.read_header(data) }
      assert_equal message, error.message, data.inspect
    end
  end

  def test_every_prefix_of_a_header_is_reported_as_truncated
    full = "P5 # comment\r\n\t3# c\n 2\n65535#\n".b + [1, 2, 3, 4, 5, 6].pack("n*")
    header_size = Pnm.read_header(full).offset
    assert_equal full.bytesize - 12, header_size

    (0...header_size).each do |length|
      error = assert_raises(ZXingFFI::UnsupportedInput, "prefix #{length}") { Pnm.decode(full.byteslice(0, length)) }
      assert_match(/\A(truncated PNM header: |not a PNM image: no data\z)/, error.message, "prefix #{length}")
    end
    (header_size...full.bytesize).each do |length|
      error = assert_raises(ZXingFFI::UnsupportedInput, "prefix #{length}") { Pnm.decode(full.byteslice(0, length)) }
      assert_equal "truncated PNM: expected 12 bytes of pixel data, got #{length - header_size}", error.message
    end
    assert_equal [0, 0, 0, 0, 0, 0], decode_bytes(full)
  end

  def test_read_header_rejects_other_types
    error = assert_raises(TypeError) { Pnm.read_header(42) }
    assert_match(/String or an IO, got Integer/, error.message)
    assert_raises(TypeError) { Pnm.decode(nil) }
    assert_raises(TypeError) { Pnm.decode(:p5) }
  end

  # --- P5 ----------------------------------------------------------------------------------------------------

  def test_p5_8bit_maxval_255_is_identity
    pixels = (0..255).to_a.pack("C*")
    decoded = Pnm.decode(pgm(16, 16, pixels))

    assert_equal [16, 16], [decoded.width, decoded.height]
    assert_equal pixels, decoded.pixels
    assert_equal Encoding::BINARY, decoded.pixels.encoding
  end

  def test_p5_maxval_15_scales_to_full_range
    pixels = decode_bytes(pgm(16, 1, (0..15).to_a.pack("C*"), maxval: 15))

    assert_equal (0..15).map { |v| v * 17 }, pixels
  end

  def test_p5_maxval_100_scales_with_rounding
    values = [0, 1, 2, 49, 50, 51, 99, 100]
    pixels = decode_bytes(pgm(values.size, 1, values.pack("C*"), maxval: 100))

    assert_equal [0, 3, 5, 125, 128, 130, 252, 255], pixels
    assert_equal values.map { |v| scale(v, 100) }, pixels
  end

  def test_p5_8bit_scaling_matches_the_formula_for_every_value_and_maxval
    (1..254).each do |maxval|
      values = (0..maxval).to_a
      assert_equal values.map { |v| scale(v, maxval) }, decode_bytes(pgm(values.size, 1, values.pack("C*"), maxval: maxval)), "maxval #{maxval}"
    end
  end

  def test_p5_maxval_1_is_bilevel_with_1_as_white
    assert_equal [0, 255, 255, 0], decode_bytes(pgm(4, 1, "\x00\x01\x01\x00", maxval: 1))
  end

  def test_p5_values_above_maxval_are_clamped_to_white
    assert_equal [255, 255, 255, 255], decode_bytes(pgm(4, 1, [16, 45, 92, 255].pack("C*"), maxval: 15))
    assert_equal [0, 255, 255], decode_bytes(pgm(3, 1, [0, 1000, 65_535].pack("n*"), maxval: 999))
  end

  def test_p5_bytes_special_to_tr_are_mapped_correctly
    # "-", "\\" and "^" are special in String#tr; make sure they are scaled like any other byte
    values = [45, 92, 94, 0, 255]
    assert_equal values.map { |v| (v > 200) ? 255 : scale(v, 200) }, decode_bytes(pgm(5, 1, values.pack("C*"), maxval: 200))
    # and that scaled values landing on them are produced correctly (maxval 254: 45 -> 45, 92 -> 92, 94 -> 94)
    assert_equal [45, 92, 94].map { |v| scale(v, 254) }, decode_bytes(pgm(3, 1, [45, 92, 94].pack("C*"), maxval: 254))
  end

  def test_p5_16bit_maxval_65535
    values = [0, 65_535, 32_768, 128, 129, 257, 256, 65_279]
    pixels = decode_bytes(pgm(values.size, 1, values.pack("n*"), maxval: 65_535))

    assert_equal [0, 255, 128, 0, 1, 1, 1, 254], pixels
    assert_equal values.map { |v| scale(v, 65_535) }, pixels
  end

  def test_p5_16bit_is_scaled_not_truncated_or_clipped
    # The high byte would give [0, 201] and clipping [255, 255]; scaling rounds v * 255 / 65535.
    assert_equal [1, 200], decode_bytes(pgm(2, 1, [255, 51_500].pack("n*"), maxval: 65_535))
  end

  def test_p5_16bit_maxval_1023
    values = [0, 1, 2, 3, 511, 512, 1020, 1021, 1023]
    pixels = decode_bytes(pgm(values.size, 1, values.pack("n*"), maxval: 1023))

    assert_equal [0, 0, 0, 1, 127, 128, 254, 255, 255], pixels
    assert_equal values.map { |v| scale(v, 1023) }, pixels
  end

  def test_p5_16bit_scaling_matches_the_formula_for_many_maxvals
    [256, 257, 300, 1000, 4095, 32_767, 65_534, 65_535].each do |maxval|
      values = (0..maxval).step([maxval / 500, 1].max).to_a << maxval
      assert_equal values.map { |v| scale(v, maxval) }, decode_bytes(pgm(values.size, 1, values.pack("n*"), maxval: maxval)), "maxval #{maxval}"
    end
  end

  def test_p5_16bit_maxval_256_is_two_bytes_per_sample
    values = (0..256).to_a
    pixels = decode_bytes(pgm(values.size, 1, values.pack("n*"), maxval: 256))

    assert_equal values.map { |v| scale(v, 256) }, pixels
    assert_equal 255, pixels.last
  end

  def test_p5_multiple_rows
    decoded = Pnm.decode(pgm(3, 2, "abcdef"))

    assert_equal [3, 2, "abcdef"], [decoded.width, decoded.height, decoded.pixels]
  end

  def test_p5_truncated_raster
    error = assert_unsupported(pgm(4, 4, "abc"), /\Atruncated PNM: expected 16 bytes of pixel data, got 3\z/)
    assert_kind_of ZXingFFI::Error, error
    assert_unsupported pgm(4, 4, "", maxval: 65_535), /expected 32 bytes of pixel data, got 0\z/
    assert_unsupported pgm(2, 1, "\x00\x01\x02", maxval: 65_535), /expected 4 bytes of pixel data, got 3\z/
  end

  def test_trailing_bytes_are_ignored
    assert_equal [1, 2, 3, 4], decode_bytes(pgm(2, 2, "\x01\x02\x03\x04garbage"))
    assert_equal [0, 255], decode_bytes(pgm(2, 1, "\x00\x00\xFF\xFFmore", maxval: 65_535))
    # a second image in the same stream
    assert_equal [7], decode_bytes(pgm(1, 1, "\x07") + pgm(1, 1, "\x09"))
    assert_equal [255, 0], decode_bytes("P4\n2 1\n\x40\xFFjunk".b)
    assert_equal [76], decode_bytes("P6\n1 1\n255\n\xFF\x00\x00trailing".b)
    assert_equal [0, 255], decode_bytes("P1\n2 1\n1 0\njunk after the raster\n")
    assert_equal [1, 2], decode_bytes("P2\n2 1\n255\n1 2 junk 7\n")
  end

  # --- P4 ----------------------------------------------------------------------------------------------------

  def test_p4_byte_aligned
    raster = [0b10110000, 0b00000001].pack("C*")

    assert_equal [0, 255, 0, 0, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 0],
      decode_bytes("P4\n8 2\n".b + raster)
  end

  def test_p4_width_not_a_multiple_of_8_drops_padding
    # padding bits are set to 1 (black) to prove they are ignored
    raster = [0b10101010, 0b10111111, 0b00000000, 0b01111111].pack("C*")
    decoded = Pnm.decode("P4\n10 2\n".b + raster)

    assert_equal 20, decoded.pixels.bytesize
    assert_equal [0, 255] * 5 + [255] * 9 + [0], decoded.pixels.bytes
  end

  def test_p4_width_1_and_13
    assert_equal [0, 255, 0], decode_bytes("P4\n1 3\n".b + [0xFF, 0x7F, 0x80].pack("C*"))
    row = [0b11110000, 0b11111111].pack("C*") # 13 pixels: 1111 0000 1111 1 + padding 111
    assert_equal [0] * 4 + [255] * 4 + [0] * 5, decode_bytes("P4 13 1\n".b + row)
    assert_equal ([0] * 4 + [255] * 4 + [0] * 5) * 2, decode_bytes("P4 13 2\n".b + row * 2)
  end

  def test_p4_large_image_matches_a_reference_implementation
    width = 37
    height = 29
    row_bytes = (width + 7) / 8
    raster = Random.new(11).bytes(row_bytes * height)
    expected = (0...height).flat_map do |y|
      (0...width).map { |x| raster.getbyte(y * row_bytes + x / 8)[7 - x % 8].zero? ? 255 : 0 }
    end

    assert_equal expected, decode_bytes("P4\n#{width} #{height}\n".b + raster)
  end

  def test_p4_truncated_raster
    assert_unsupported "P4\n10 2\n\x00\x00\x00".b, /\Atruncated PNM: expected 4 bytes of pixel data, got 3\z/
  end

  # --- P6 ----------------------------------------------------------------------------------------------------

  def test_p6_pure_colours_use_the_zxing_formula
    colours = [[255, 0, 0], [0, 255, 0], [0, 0, 255], [255, 255, 255], [0, 0, 0], [12, 200, 99]]
    pixels = decode_bytes("P6\n6 1\n255\n".b + colours.flatten.pack("C*"))

    assert_equal colours.map { |c| lum(*c) }, pixels
    assert_equal [76, 150, 29, 255, 0], pixels.first(5)
  end

  def test_p6_random_pixels_match_the_formula
    rgb = Random.new(5).bytes(3 * 40 * 30)
    expected = rgb.bytes.each_slice(3).map { |r, g, b| lum(r, g, b) }

    assert_equal expected, decode_bytes("P6 40 30 255\n".b + rgb)
  end

  def test_p6_8bit_maxval_below_255_scales_channels_first
    pixels = decode_bytes("P6\n2 1\n15\n".b + [15, 0, 0, 5, 10, 15].pack("C*"))

    assert_equal [lum(255, 0, 0), lum(85, 170, 255)], pixels
  end

  def test_p6_16bit_scales_channels_then_applies_the_formula
    samples = [65_535, 0, 0, 0, 65_535, 0, 0, 0, 65_535, 32_768, 32_768, 32_768, 65_535, 65_535, 65_535]
    pixels = decode_bytes("P6\n5 1\n65535\n".b + samples.pack("n*"))

    assert_equal [76, 150, 29, 128, 255], pixels
    assert_equal samples.each_slice(3).map { |c| lum(*c.map { |v| scale(v, 65_535) }) }, pixels
  end

  def test_p6_truncated_raster
    assert_unsupported "P6\n2 2\n255\n".b + "\x00" * 11, /\Atruncated PNM: expected 12 bytes of pixel data, got 11\z/
    assert_unsupported "P6\n2 2\n1000\n".b + "\x00" * 23, /\Atruncated PNM: expected 24 bytes of pixel data, got 23\z/
  end

  # --- ASCII variants ----------------------------------------------------------------------------------------

  def test_p1_separated_and_unseparated
    assert_equal [255, 0, 255, 0, 0, 255, 0, 255], decode_bytes("P1\n4 2\n0 1 0 1\n1 0 1 0\n")
    assert_equal [255, 0, 255, 0, 0, 255, 0, 255], decode_bytes("P1\n4 2\n0101\n1010\n")
    assert_equal [255, 0, 255, 0, 0, 255, 0, 255], decode_bytes("P1\n4 2\n01011010")
    assert_equal [255, 0, 255, 0, 0, 255, 0, 255], decode_bytes("P1 4 2\n0\t10  1\r\n1 0\v1\f0")
  end

  def test_p1_comments_in_the_raster_are_skipped
    assert_equal [0, 255, 255, 0], decode_bytes("P1\n2 2\n1 0 # first row\n# a full line\n0 1\n")
  end

  def test_p1_invalid_and_truncated_rasters
    assert_unsupported "P1\n2 2\n0 1 2 0\n", /\Amalformed PNM raster: expected 0 or 1 in a P1 image, got "2"\z/
    assert_unsupported "P1\n2 2\n0 1 1\n", /\Atruncated PNM: expected 4 bits of pixel data, got 3\z/
    assert_unsupported "P1\n2 2\n", /\Atruncated PNM: expected 4 bits of pixel data, got 0\z/
  end

  def test_p2_scaling_and_comments
    assert_equal [0, 17, 34, 221, 238, 255], decode_bytes("P2\n3 2\n15\n0 1 2\n13 14 # c\n 15\n")
    assert_equal [0, 128, 255], decode_bytes("P2 3 1 255\n0 128 255")
    assert_equal [0, 128, 255], decode_bytes("P2 3 1 65535\n00000 32768\t65535\r\n")
    assert_equal [scale(1, 1023), 255], decode_bytes("P2 2 1 1023\n1 5000\n")
  end

  def test_p2_huge_sample_is_clamped
    assert_equal [255, 0], decode_bytes("P2 2 1 255\n#{"9" * 40} 0\n")
  end

  def test_p2_invalid_and_truncated_rasters
    assert_unsupported "P2\n2 1\n255\n12a 3\n", /\Amalformed PNM raster: expected decimal samples, got "12a"\z/
    assert_unsupported "P2\n2 1\n255\n-1 3\n", /got "-1"/
    assert_unsupported "P2\n2 1\n255\n1.5 3\n", /got "1.5"/
    assert_unsupported "P2\n2 2\n255\n1 2 3\n", /\Atruncated PNM: expected 4 samples of pixel data, got 3\z/
    assert_unsupported "P2\n2 2\n255\n1 2 3", /got 3\z/
    assert_unsupported "P2\n2 2\n255\n", /got 0\z/
  end

  def test_p3_colours
    pixels = decode_bytes("P3\n3 1\n255\n255 0 0  0 255 0\n0 0 255\n")
    assert_equal [76, 150, 29], pixels

    pixels = decode_bytes("P3 2 1 65535 # comment\n65535 65535 65535 # white\n 32768 32768 32768")
    assert_equal [255, 128], pixels
    assert_unsupported "P3 2 1 255\n1 2 3 4 5\n", /expected 6 samples of pixel data, got 5\z/
  end

  def test_every_variant_returns_binary_pixels
    [
      pgm(1, 1, "\x05"), pgm(1, 1, "\x05", maxval: 15), pgm(1, 1, "\x00\x05", maxval: 1000),
      "P4 1 1\n\x80".b, "P6 1 1 255\n\x01\x02\x03".b, "P6 1 1 65535\n\x00\x01\x00\x02\x00\x03".b,
      "P1 1 1\n1", "P2 1 1 255\n5", "P3 1 1 255\n1 2 3"
    ].each do |data|
      pixels = Pnm.decode(data.dup.force_encoding(Encoding::UTF_8)).pixels
      assert_equal Encoding::BINARY, pixels.encoding, data.inspect
      assert_equal 1, pixels.bytesize, data.inspect
    end
  end

  # --- max_pixels -------------------------------------------------------------------------------------------

  def test_max_pixels_allows_images_up_to_the_limit
    assert_equal 6, Pnm.decode(pgm(3, 2, "abcdef"), max_pixels: 6).pixels.bytesize
  end

  def test_max_pixels_is_checked_before_the_raster
    # Only the header is present: exceeding the limit must win over "truncated".
    error = assert_raises(ZXingFFI::LimitExceeded) { Pnm.decode("P5\n40000 30000\n255\n", max_pixels: 64_000_000) }

    assert_equal :max_pixels, error.limit
    assert_equal 1_200_000_000, error.value
    assert_equal "PNM image is 40000x30000 (1200000000 pixels), more than max_pixels (64000000)", error.message
    assert_kind_of ZXingFFI::Error, error
  end

  def test_max_pixels_applies_to_every_variant
    ["P1 3 3\n", "P2 3 3 255\n", "P3 3 3 255\n", "P4 3 3\n", "P5 3 3 255\n", "P6 3 3 65535\n"].each do |data|
      error = assert_raises(ZXingFFI::LimitExceeded, data) { Pnm.decode(data, max_pixels: 8) }
      assert_equal 9, error.value
    end
  end

  # --- IO input ---------------------------------------------------------------------------------------------

  def test_decode_from_stringio
    io = StringIO.new(pgm(2, 2, "\x01\x02\x03\x04") + "trailing")
    decoded = Pnm.decode(io)

    assert_equal [2, 2, [1, 2, 3, 4]], [decoded.width, decoded.height, decoded.pixels.bytes]
    assert_equal Encoding::BINARY, decoded.pixels.encoding
  end

  def test_decode_from_a_file
    in_tmpdir do |dir|
      path = File.join(dir, "image.pgm")
      raster = Random.new(3).bytes(300 * 200)
      File.binwrite(path, pgm(300, 200, raster))

      decoded = File.open(path, "rb") { |file| Pnm.decode(file) }
      assert_equal raster, decoded.pixels
      decoded = File.open(path) { |file| Pnm.decode(file) } # text mode is fine on POSIX
      assert_equal raster, decoded.pixels
    end
  end

  def test_decode_from_a_pipe
    reader, writer = IO.pipe
    data = pgm(64, 64, Random.new(4).bytes(64 * 64))
    thread = Thread.new do
      writer.write(data)
    ensure
      writer.close
    end

    assert_equal data.byteslice(-4096, 4096), Pnm.decode(reader).pixels
  ensure
    thread&.join
    reader&.close
  end

  def test_decode_from_io_starts_at_the_current_position
    io = StringIO.new("junk" + pgm(1, 2, "\x05\x06"))
    io.read(4)

    assert_equal [5, 6], Pnm.decode(io).pixels.bytes
  end

  def test_io_header_longer_than_the_first_read
    comment = "# #{"x" * 10_000}\n"
    data = "P5\n#{comment}3 1\n#{comment}255\n".b + "\x01\x02\x03"

    assert_equal [1, 2, 3], Pnm.decode(StringIO.new(data)).pixels.bytes
    assert_equal Pnm.read_header(data), Pnm.read_header(StringIO.new(data))
  end

  def test_io_header_split_at_every_position_around_the_first_read
    raster = [0, 65_535, 257, 32_768, 65_000, 1].pack("n*")
    (4070..4100).each do |padding|
      # the 4096-byte boundary falls in the comment, a number, the separators or the delimiter
      data = "P5\n##{"c" * padding}\n000006\t\t\t00001\n65535\n".b + raster + "tail"
      decoded = Pnm.decode(StringIO.new(data))
      assert_equal Pnm.decode(data), decoded, "padding #{padding}"
      assert_equal [6, 1, [0, 255, 1, 128, 253, 0]], [decoded.width, decoded.height, decoded.pixels.bytes]
    end
  end

  def test_io_errors_match_string_errors
    ["", "P", "P5 2", "P5 2 2 255", "P5 2 2 255\nab", "GIF89a", "P5 x", "P1 2 1\n2 2"].each do |data|
      from_string = assert_raises(ZXingFFI::UnsupportedInput) { Pnm.decode(data) }
      from_io = assert_raises(ZXingFFI::UnsupportedInput) { Pnm.decode(StringIO.new(data)) }
      assert_equal from_string.message, from_io.message, data.inspect
    end
  end

  def test_io_max_pixels_is_checked_before_reading_the_raster
    io = StringIO.new(pgm(1000, 1000, "\x00" * 1_000_000))

    assert_raises(ZXingFFI::LimitExceeded) { Pnm.decode(io, max_pixels: 999_999) }
    assert_operator io.pos, :<=, 4096
  end

  def test_io_with_huge_announced_size_is_reported_as_truncated
    io = StringIO.new("P5\n2000000000 2000000000\n65535\nsmall")
    error = assert_raises(ZXingFFI::UnsupportedInput) { Pnm.decode(io) }

    assert_equal "truncated PNM: expected 8000000000000000000 bytes of pixel data, got 5", error.message
  end

  def test_io_stops_reading_after_the_raster
    reader, writer = IO.pipe
    thread = Thread.new do
      writer.write("P5\n1000 50\n255\n" + "\x01" * 50_000 + "NEXT")
    ensure
      writer.close
    end

    assert_equal 50_000, Pnm.decode(reader).pixels.bytesize
    # the raster ends past the first header read, so the rest of the stream is untouched
    assert_equal "NEXT", reader.read
  ensure
    thread&.join
    reader&.close
  end

  # An endless comment in an untrusted stream must not be buffered without bound (Image.from_pgm takes any IO).
  def test_io_header_is_limited
    endless = Object.new # a comment that never ends (it stops after 8 MiB so that a regression fails, not hangs)
    endless.define_singleton_method(:read) do |length|
      next nil if (@read || 0) >= 8 * 1024 * 1024

      @read = (@read || 0) + length
      (@read == length) ? "P5\n#".b + ("c" * (length - 4)) : ("c" * length).b
    end
    endless.define_singleton_method(:bytes_read) { @read }

    error = assert_raises(ZXingFFI::UnsupportedInput) { ZXingFFI::Pnm.decode(endless) }
    assert_match(/header longer than 1048576 bytes/, error.message)
    assert_equal ZXingFFI::Pnm::MAX_HEADER_BYTES, endless.bytes_read

    header = "P5\n#{"# #{"c" * 1000}\n" * 1000}2 1\n255\n".b # ~1 MB of comments still fits
    assert_equal "\x00\xFF".b, ZXingFFI::Pnm.decode(StringIO.new(header + "\x00\xFF".b)).pixels
  end

  def test_read_header_from_io_restores_the_position
    io = StringIO.new("xx" + pgm(3, 1, "abc"))
    io.seek(2)
    header = Pnm.read_header(io)

    assert_equal [3, 1, 11], [header.width, header.height, header.offset]
    assert_equal 2, io.pos
  end

  def test_read_header_from_io_restores_the_position_on_error
    io = StringIO.new("P5 2 x")

    assert_raises(ZXingFFI::UnsupportedInput) { Pnm.read_header(io) }
    assert_equal 0, io.pos
  end

  def test_read_header_from_a_pipe
    reader, writer = IO.pipe
    writer.write("P6 7 5 255\n")
    writer.close

    assert_equal [:p6, 7, 5], Pnm.read_header(reader).to_h.values_at(:kind, :width, :height)
  ensure
    reader&.close
  end

  # --- encode_pgm ---------------------------------------------------------------------------------------------

  def test_encode_pgm
    data = Pnm.encode_pgm("\x00\x01\xFE\xFF".b, 2, 2)

    assert_equal "P5\n2 2\n255\n\x00\x01\xFE\xFF".b, data
    assert_equal Encoding::BINARY, data.encoding
  end

  def test_encode_pgm_accepts_any_encoding
    pixels = "éè" # 4 bytes in UTF-8
    data = Pnm.encode_pgm(pixels, 4, 1)

    assert_equal Encoding::BINARY, data.encoding
    assert_equal "P5\n4 1\n255\n".b + pixels.b, data
    assert_equal Encoding::UTF_8, pixels.encoding
  end

  def test_encode_decode_round_trip
    [[1, 1], [7, 3], [640, 480]].each do |width, height|
      pixels = Random.new(width).bytes(width * height)
      decoded = Pnm.decode(Pnm.encode_pgm(pixels, width, height))

      assert_equal Pnm::Decoded.new(width: width, height: height, pixels: pixels), decoded
    end
  end

  def test_encode_pgm_validates_arguments
    error = assert_raises(ArgumentError) { Pnm.encode_pgm("abc", 2, 2) }
    assert_equal "expected 4 bytes of pixels for 2x2, got 3", error.message
    assert_raises(ArgumentError) { Pnm.encode_pgm("abcde", 2, 2) }
    assert_raises(ArgumentError) { Pnm.encode_pgm("", 0, 0) }
    assert_raises(ArgumentError) { Pnm.encode_pgm("ab", -2, -1) }
    assert_raises(ArgumentError) { Pnm.encode_pgm("abcd", 2.0, 2) }
    assert_raises(TypeError) { Pnm.encode_pgm(nil, 1, 1) }
  end

  # --- Chunked conversion -----------------------------------------------------------------------------------
  # Rasters are converted in steps of 16Ki pixels (64 KiB of text for P1-P3); these images span many steps.

  def test_binary_variants_spanning_many_steps_match_a_reference
    rng = Random.new(21)
    width = 307
    height = 211 # 64,777 pixels, not a multiple of any step
    n = width * height
    samples16 = Array.new(3 * n) { rng.rand(1100) } # some above maxval 1000
    {
      "P5 16-bit" => ["P5 #{width} #{height} 65535\n", rng.bytes(2 * n), ->(raw) { reference_gray(raw.unpack("n*"), 65_535) }],
      "P5 16-bit maxval 1000" => ["P5 #{width} #{height} 1000\n", samples16.first(n).pack("n*"), ->(raw) { reference_gray(raw.unpack("n*"), 1000) }],
      "P5 8-bit maxval 200" => ["P5 #{width} #{height} 200\n", rng.bytes(n), ->(raw) { reference_gray(raw.bytes, 200) }],
      "P6 8-bit" => ["P6 #{width} #{height} 255\n", rng.bytes(3 * n), ->(raw) { reference_rgb(raw.bytes, 255) }],
      "P6 8-bit maxval 100" => ["P6 #{width} #{height} 100\n", rng.bytes(3 * n), ->(raw) { reference_rgb(raw.bytes, 100) }],
      "P6 16-bit maxval 1000" => ["P6 #{width} #{height} 1000\n", samples16.pack("n*"), ->(raw) { reference_rgb(raw.unpack("n*"), 1000) }],
      "P4 odd width" => ["P4 #{width} #{height}\n", rng.bytes((width + 7) / 8 * height), ->(raw) { reference_bits(raw, width, height) }],
      "P4 width 1024" => ["P4 1024 70\n", rng.bytes(128 * 70), ->(raw) { reference_bits(raw, 1024, 70) }],
      # rows wider than a step (16Ki pixels) are cut between steps, at varying positions
      "P4 wide rows" => ["P4 40001 5\n", rng.bytes(5001 * 5), ->(raw) { reference_bits(raw, 40_001, 5) }],
      "P4 wide rows, no padding" => ["P4 40000 5\n", rng.bytes(5000 * 5), ->(raw) { reference_bits(raw, 40_000, 5) }],
      "P4 row of exactly one step" => ["P4 16383 3\n", rng.bytes(2048 * 3), ->(raw) { reference_bits(raw, 16_383, 3) }]
    }.each do |name, (header, raster, reference)|
      data = header.b + raster + "trailing junk".b
      expected = reference.call(raster)
      assert_equal expected, decode_bytes(data), name
      assert_equal expected, decode_bytes(StringIO.new(data)), "#{name} from an IO"
    end
  end

  def test_8bit_p5_from_an_io_spanning_many_steps
    raster = Random.new(22).bytes(700 * 500) # more than one 256 KiB step
    [255, 200].each do |maxval|
      data = pgm(700, 500, raster, maxval: maxval) + "junk"
      assert_equal reference_gray(raster.bytes, maxval), decode_bytes(StringIO.new(data)), "maxval #{maxval}"
    end
  end

  def test_random_plain_rasters_spanning_many_chunks_match_a_reference
    [[:p1, 1, 211, 997], [:p2, 255, 150, 400], [:p2, 65_535, 120, 300], [:p3, 1000, 90, 250]].each_with_index do |(kind, maxval, width, height), seed|
      rng = Random.new(seed)
      count = width * height * ((kind == :p3) ? 3 : 1)
      text = random_plain_text(rng, count, maxval, bits: kind == :p1)
      assert_operator text.bytesize, :>, 4 * 64 * 1024, "#{kind} raster should span several chunks"
      header = (kind == :p1) ? "P1\n#{width} #{height}\n" : "#{kind.upcase}\n#{width} #{height}\n#{maxval}\n"
      data = header.b + text + " 1 0 junk after the raster ##{"z" * 70_000}"
      expected = reference_plain(kind, text, count, maxval)

      assert_equal expected, decode_bytes(data), "#{kind} maxval #{maxval}"
      assert_equal expected, decode_bytes(StringIO.new(data)), "#{kind} maxval #{maxval} from an IO"
    end
  end

  def test_plain_tokens_and_comments_cut_at_a_chunk_boundary
    header = "P2\n7 1\n65535\n"
    boundary = 64 * 1024 # raster-relative position where the first chunk ends
    ["12345", "123#comment\n", "#comment\n", "0000000009", "\r\n"].each do |special|
      (-special.bytesize - 1..1).each do |shift|
        start = boundary + shift # where +special+ begins
        filler = " " * (start - 12)
        raster = "1 2 3 4 5 6 " + filler + special + " 777 888 999"
        expected = reference_plain(:p2, raster, 7, 65_535)
        assert_equal 7, expected.size
        data = (header + raster).b

        assert_equal expected, decode_bytes(data), "#{special.inspect} at #{start}"
        assert_equal expected, decode_bytes(StringIO.new(data)), "#{special.inspect} at #{start} from an IO"
      end
    end
  end

  def test_plain_token_or_comment_longer_than_a_chunk
    long_zeros = "0" * 150_000
    assert_equal [7, 3], decode_bytes("P2 2 1 255\n#{long_zeros}7 3\n")
    assert_equal [255, 3], decode_bytes("P2 2 1 255\n#{"9" * 150_000} 3\n")
    assert_equal [1, 2], decode_bytes("P2 2 1 255\n1 # #{"c" * 200_000}\n2\n")
    assert_equal [1, 2], decode_bytes("P2 2 1 255\n1#{"#" * 200_000}\r2")
    assert_equal [0, 255, 0], decode_bytes("P1 3 1\n1#{"#c" * 100_000}\n0 1")
    assert_equal [255, 0] * 70_000, decode_bytes("P1 140000 1\n#{"01" * 70_000}")
  end

  def test_samples_cut_by_many_chunks_keep_their_value
    # A sample spanning chunks is kept short while it is read (found by a code review: it used to
    # grow with the data); its value must be the one a single pass computes.
    [65_535, 65_536, 65_537, 131_072, 200_000].each do |length|
      ["", "7", "65535", "65536", "32768", "123456", "1" + "0" * 30].each do |digits|
        [65_535, 1023].each do |maxval|
          token = "0" * (length - digits.bytesize) + digits
          text = "1 #{token} 3\n"
          expected = reference_plain(:p2, text, 3, maxval)
          data = "P2 3 1 #{maxval}\n#{text}"
          assert_equal expected, decode_bytes(data), "#{length} bytes ending in #{digits.inspect}, maxval #{maxval}"
          assert_equal expected, decode_bytes(StringIO.new(data)), "#{length} bytes ending in #{digits.inspect} from an IO"
        end
      end
    end
    assert_equal [255, 3], decode_bytes("P2 2 1 255\n00000000000000000001#{"0" * 150_000} 3\n")
    assert_equal [255, 3], decode_bytes("P2 2 1 255\n#{"0" * 100_000}1#{"0" * 100_000} 3\n")
    assert_equal [lum(255, 1, 2), 0], decode_bytes("P3 2 1 255\n#{"9" * 150_000} 1 2 0 0 #{"0" * 150_000}")
  end

  def test_invalid_samples_cut_by_many_chunks_are_named_by_their_start
    {
      "#{"0" * 150_000}x 5" => "0" * 20,
      "#{"1" * 150_000}x5 5" => "1" * 20,
      "12x#{"4" * 150_000} 5" => "12x#{"4" * 17}",
      "#{"7" * 100}x#{"7" * 200_000} 5" => "7" * 20, # only digits after the chunk holding the "x"
      "#{"\0" * 150_000} 5" => "\0" * 20,
      "#{"7" * 150_000}#{"\0" * 150_000} 5" => "7" * 20
    }.each do |text, shown|
      data = "P2 2 1 255\n#{text}"
      message = "malformed PNM raster: expected decimal samples, got #{shown.b.inspect}"
      assert_equal message, assert_raises(ZXingFFI::UnsupportedInput) { Pnm.decode(data) }.message
      assert_equal message, assert_raises(ZXingFFI::UnsupportedInput) { Pnm.decode(StringIO.new(data)) }.message
    end
    # Too few samples wins, however long the invalid one.
    assert_unsupported "P2 2 2 255\n#{"\0" * 150_000} 5", /\Atruncated PNM: expected 4 samples of pixel data, got 2\z/
  end

  def test_a_comment_after_every_pixel
    width = 300
    height = 200
    # a comment after (nearly) every sample, LF- or CR-terminated, cut by chunk ends at every offset
    {
      p1: ["P1 #{width} #{height}\n", "1#\n0#c\r", 2, width * height],
      p2: ["P2 #{width} #{height} 255\n", "12#c\n7 #\r\n", 2, width * height],
      p3: ["P3 #{width} #{height} 1000\n", "999#x#\n0\t#\r5 ", 3, width * height * 3]
    }.each do |kind, (header, unit, samples_per_unit, count)|
      text = unit * (count / samples_per_unit + 1)
      expected = reference_plain(kind, text, count, (kind == :p3) ? 1000 : 255)
      data = header + text

      assert_equal expected, decode_bytes(data), kind
      assert_equal expected, decode_bytes(StringIO.new(data)), "#{kind} from an IO"
    end
  end

  def test_plain_errors_across_chunks_keep_their_precedence
    filler = "1 " * 40_000 # 80,000 bytes: more than one chunk
    # An invalid sample, but too few samples overall: reported as truncated, as by a single pass.
    assert_unsupported "P2 300 300 255\nx #{filler}", /\Atruncated PNM: expected 90000 samples of pixel data, got 40001\z/
    assert_unsupported "P1 400 400\nx#{"01" * 50_000}", /\Atruncated PNM: expected 160000 bits of pixel data, got 100001\z/
    # Enough samples: the first invalid one is named, even when a chunk boundary cuts it.
    raster = "1 " * 32_767 + "12x45 " + filler
    assert_equal 65_534, raster.index("12x45")
    assert_unsupported "P2 100 700 255\n#{raster}", /\Amalformed PNM raster: expected decimal samples, got "12x45"\z/
    assert_unsupported "P2 100 700 255\n#{raster.sub("12x45", "1" * 30 + "x")}", /got "#{"1" * 20}"\z/
    assert_unsupported "P1 400 200\n#{"01" * 35_000}2#{"0" * 10_000}", /\Amalformed PNM raster: expected 0 or 1 in a P1 image, got "2"\z/
    # ...but anything after the needed bits or samples is ignored, even in a later chunk.
    assert_equal [255, 0] * 40_000, decode_bytes("P1 400 200\n#{"01" * 40_000}2#{"0" * 100}")
  end

  # --- Bounded memory ---------------------------------------------------------------------------------------

  # Largest String or Array a decode may create besides its output. Steps stay well below it whatever the
  # image size: the biggest temporaries are the 16-bit scale table (512 KiB) and one step's samples unpacked
  # into an Array (16Ki pixels x 3 channels x 8 bytes = 384 KiB). Converting the inputs below in one piece
  # needs a single temporary of more than 2 MiB (a whole raster, token list or sample).
  TEMPORARY_LIMIT = 1024 * 1024

  def test_decoding_needs_bounded_temporary_memory
    skip "measuring object sizes needs CRuby" unless RUBY_ENGINE == "ruby"

    rng = Random.new(31)
    {
      "P6 8-bit" => "P6 300 300 255\n".b + rng.bytes(3 * 90_000),
      "P6 16-bit" => "P6 300 300 65535\n".b + rng.bytes(6 * 90_000),
      "P5 16-bit" => "P5 600 450 65535\n".b + rng.bytes(2 * 270_000),
      "P4" => "P4 2001 1100\n".b + rng.bytes(251 * 1100),
      "P4 one wide row" => "P4 2500001 1\n".b + rng.bytes(312_501),
      "P3" => "P3 300 300 255\n".b + "12 255 0 7 99 128\n" * 45_000,
      "P2" => "P2 600 450 255\n".b + "12 255 0 7 99 128\n" * 45_000,
      "P2 one long sample" => "P2 3 1 255\n1 #{"0" * 2_500_000}7 3\n".b,
      "P1" => "P1 1500 1400\n".b + "0110 1001\n" * 262_500
    }.each do |name, data|
      [data, StringIO.new(data)].each do |input|
        decoded, largest = largest_temporary(data) { Pnm.decode(input) }
        assert_equal decoded.width * decoded.height, decoded.pixels.bytesize
        assert_operator largest, :<=, TEMPORARY_LIMIT, "#{name} from a #{input.class}: #{largest}-byte temporary"
      end
    end
  end

  def test_a_truncated_ascii_raster_with_a_long_tail_needs_bounded_memory
    skip "measuring object sizes needs CRuby" unless RUBY_ENGINE == "ruby"

    # Like a truncated file with a sparse tail: the NUL bytes form one endless invalid sample (found by a
    # code review: it was accumulated whole).
    data = "P2 40 40 255\n1 2 3".b + "\0".b * 3_000_000
    [data, StringIO.new(data)].each do |input|
      error, largest = largest_temporary(data) { assert_raises(ZXingFFI::UnsupportedInput) { Pnm.decode(input) } }
      assert_equal "truncated PNM: expected 1600 samples of pixel data, got 3", error.message
      assert_operator largest, :<=, TEMPORARY_LIMIT, "from a #{input.class}: #{largest}-byte temporary"
    end
  end

  # Objects are allocated per step, not per pixel or per comment (P4 with padded rows: one String per row).
  # P2 and P3 allocate a String per sample, so they are not included; their memory is bounded by the step
  # size all the same.
  def test_decoding_allocates_objects_per_step_not_per_pixel
    rng = Random.new(32)
    {
      "P6 8-bit" => "P6 600 400 255\n".b + rng.bytes(3 * 240_000),
      "P6 16-bit" => "P6 600 400 65535\n".b + rng.bytes(6 * 240_000),
      "P5 8-bit" => "P5 1000 600 255\n".b + rng.bytes(600_000),
      "P5 16-bit" => "P5 1000 600 65535\n".b + rng.bytes(2 * 600_000),
      "P4" => "P4 2001 2000\n".b + rng.bytes(251 * 2000),
      "P4 one wide row" => "P4 4000001 1\n".b + rng.bytes(500_001),
      "P1" => "P1 1500 1400\n".b + "0110 1001 # c\n" * 262_500,
      "P1 with a comment per pixel" => "P1 1000 1000\n".b + "1#\n0#\r" * 500_000
    }.each do |name, data|
      [data, StringIO.new(data)].each do |input|
        before = GC.stat(:total_allocated_objects)
        decoded = Pnm.decode(input)
        allocated = GC.stat(:total_allocated_objects) - before
        assert_operator allocated, :<, decoded.pixels.bytesize / 100, "#{name} from a #{input.class}: #{allocated} objects"
      end
    end
  end

  # --- IO reads stop at the raster ------------------------------------------------------------------------

  def test_io_with_a_huge_tail_is_read_exactly_up_to_the_raster
    rng = Random.new(33)
    {
      "P6" => "P6 300 200 255\n".b + rng.bytes(180_000),
      "P6 16-bit" => "P6 300 200 65535\n".b + rng.bytes(360_000),
      "P5 8-bit" => "P5 700 500 255\n".b + rng.bytes(350_000),
      "P5 8-bit maxval 200" => "P5 700 500 200\n".b + rng.bytes(350_000),
      "P5 16-bit" => "P5 300 200 65535\n".b + rng.bytes(120_000),
      "P4" => "P4 1001 99\n".b + rng.bytes(126 * 99),
      "P4 wide rows" => "P4 40001 3\n".b + rng.bytes(5001 * 3)
    }.each do |name, data|
      io = TailIO.new(data, budget: data.bytesize)
      decoded = Pnm.decode(io)
      assert_equal decoded.width * decoded.height, decoded.pixels.bytesize, name
      assert_equal data.bytesize, io.bytes_read, name
    end
  end

  def test_io_holding_a_small_binary_image_is_read_by_the_first_header_chunk_only
    ["P5 40 40 255\n".b + "\x07".b * 1600, "P6 2 1 65535\n".b + "\x01".b * 12, "P4 9 9\n".b + "\xFF".b * 18].each do |data|
      io = TailIO.new(data, budget: 4096)
      decoded = Pnm.decode(io)

      assert_equal decoded.width * decoded.height, decoded.pixels.bytesize, data[0, 2]
      assert_equal 4096, io.bytes_read, data[0, 2]
    end
  end

  def test_io_max_pixels_is_checked_before_reading_past_the_first_header_chunk
    ["P1 3 3\n", "P2 3 3 255\n", "P3 3 3 255\n", "P4 3 3\n", "P5 3 3 255\n", "P6 3 3 65535\n"].each do |header|
      io = TailIO.new(header, budget: 4096)

      assert_raises(ZXingFFI::LimitExceeded, header) { Pnm.decode(io, max_pixels: 8) }
      assert_equal 4096, io.bytes_read, header
    end
  end

  def test_io_returning_short_reads
    rng = Random.new(36)
    [
      "P5 301 200 65535\n".b + rng.bytes(2 * 301 * 200),
      "P5 700 500 255\n".b + rng.bytes(350_000),
      "P6 301 200 1000\n".b + [*0..1100].pack("n*") * 165,
      "P4 40001 3\n".b + rng.bytes(5001 * 3),
      "P2 300 300 255\n" + "12 255 0 7 # c\n99\n" * 18_000,
      "P1 500 500\n" + "0 1#c\r" * 125_000
    ].each do |data|
      expected = Pnm.decode(data)
      assert_equal expected, Pnm.decode(ShortReadIO.new(data)), data[0, 16].inspect
    end
  end

  def test_truncated_binary_rasters_report_the_bytes_found_at_every_step
    rng = Random.new(35)
    {
      "P4" => ["P4 40001 5\n", 5001 * 5],
      "P5 8-bit" => ["P5 700 500 255\n", 350_000],
      "P5 8-bit maxval 200" => ["P5 700 500 200\n", 350_000],
      "P5 16-bit" => ["P5 300 200 65535\n", 120_000],
      "P6 8-bit" => ["P6 300 200 255\n", 180_000],
      "P6 16-bit" => ["P6 300 200 65535\n", 360_000]
    }.each do |name, (header, size)|
      raster = rng.bytes(size)
      [0, 1, 2047, 4095, 4096, size / 2 + 1, size - 1].each do |length|
        data = header.b + raster.byteslice(0, length)
        message = "truncated PNM: expected #{size} bytes of pixel data, got #{length}"
        assert_equal message, assert_raises(ZXingFFI::UnsupportedInput) { Pnm.decode(data) }.message, "#{name}: #{length}"
        assert_equal message, assert_raises(ZXingFFI::UnsupportedInput) { Pnm.decode(StringIO.new(data)) }.message,
          "#{name}: #{length} from an IO"
      end
    end
  end

  def test_io_with_a_huge_tail_is_read_at_most_one_text_chunk_past_an_ascii_raster
    {
      "P1" => "P1 500 500\n" + "01" * 125_000,
      "P2" => "P2 300 300 255\n" + "12 255 0 7 99\n" * 18_000,
      "P3" => "P3 200 100 255\n" + "12 255 0 7 99 128\n" * 10_000,
      "small P1" => "P1 3 1\n101",
      "small P2" => "P2 3 1 255\n1 2 3 ",
      "P2 with a long comment" => "P2 3 1 255\n1 2 # #{"c" * 200_000}\n3\n"
    }.each do |name, text|
      io = TailIO.new(text, budget: text.bytesize + 64 * 1024)
      decoded = Pnm.decode(io)
      assert_equal decoded.width * decoded.height, decoded.pixels.bytesize, name
      assert_operator io.bytes_read, :<=, text.bytesize + 64 * 1024, name
    end
  end

  def test_file_with_a_huge_sparse_tail_is_read_only_up_to_the_raster
    rng = Random.new(34)
    {
      "P6" => ["P6 300 200 255\n".b + rng.bytes(180_000), 0],
      "P5" => ["P5 300 200 255\n".b + rng.bytes(60_000), 0],
      "P5 16-bit" => ["P5 300 200 65535\n".b + rng.bytes(120_000), 0],
      "P4" => ["P4 300 200\n".b + rng.bytes(38 * 200), 0],
      # the ASCII variants read the raster in 64 KiB chunks
      "P2" => ["P2 300 200 255\n" + "12 255 0 7 99\n" * 12_000, 64 * 1024],
      "P1" => ["P1 300 200\n" + "0 1 1 0\n" * 15_000, 64 * 1024]
    }.each do |name, (data, slack)|
      in_tmpdir do |dir|
        path = File.join(dir, "tail.pnm")
        File.binwrite(path, data)
        File.truncate(path, data.bytesize + 2**30) # a 1 GiB hole after the image

        File.open(path, "rb") do |file|
          assert_equal 60_000, Pnm.decode(file).pixels.bytesize, name
          assert_operator file.pos, :>=, data.bytesize, name
          assert_operator file.pos, :<=, data.bytesize + slack, name
        end
      end
    end
  end

  # --- Performance ------------------------------------------------------------------------------------------

  def test_p5_8bit_decoding_is_fast
    data = pgm(3000, 3000, Random.new(9).bytes(9_000_000))
    decoded = nil
    elapsed = measure { decoded = Pnm.decode(data, max_pixels: 64_000_000) }

    assert_operator elapsed, :<, 0.1, "decoding 3000x3000 P5 took #{elapsed}s"
    assert_equal 9_000_000, decoded.pixels.bytesize
    assert_equal data.byteslice(-9_000_000, 9_000_000), decoded.pixels
  end

  def test_p5_8bit_scaled_decoding_is_fast
    data = pgm(3000, 3000, Random.new(9).bytes(9_000_000), maxval: 254)
    elapsed = measure { Pnm.decode(data) }

    assert_operator elapsed, :<, 0.2, "decoding 3000x3000 P5 maxval 254 took #{elapsed}s"
  end

  def test_p5_16bit_decoding_is_reasonably_fast
    raster = Random.new(10).bytes(2 * 2000 * 2000)
    decoded = nil
    elapsed = measure { decoded = Pnm.decode(pgm(2000, 2000, raster, maxval: 65_535)) }

    assert_operator elapsed, :<, 3.0, "decoding 2000x2000 16-bit P5 took #{elapsed}s"
    [0, 1, 1999, 2_000_000, 3_999_999].each do |i|
      assert_equal scale(raster.unpack1("n", offset: 2 * i), 65_535), decoded.pixels.getbyte(i)
    end
  end

  def test_p4_decoding_is_fast
    raster = Random.new(12).bytes((2550 + 7) / 8 * 3300) # A4 fax page at 300 dpi
    elapsed = measure { Pnm.decode("P4 2550 3300\n".b + raster) }

    assert_operator elapsed, :<, 0.5, "decoding 2550x3300 P4 took #{elapsed}s"
  end

  private

  def measure
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
  end

  # Samples (Integers) scaled one at a time.
  def reference_gray(samples, maxval)
    samples.map { |v| (v > maxval) ? 255 : scale(v, maxval) }
  end

  def reference_rgb(samples, maxval)
    reference_gray(samples, maxval).each_slice(3).map { |rgb| lum(*rgb) }
  end

  # P4 bit by bit: 1 is black; each row is padded to a byte boundary.
  def reference_bits(raster, width, height)
    row_bytes = (width + 7) / 8
    (0...height).flat_map do |y|
      (0...width).map { |x| raster.getbyte(y * row_bytes + x / 8)[7 - x % 8].zero? ? 255 : 0 }
    end
  end

  # The ASCII variants in one pass over the whole raster: drop comments, then split into samples (or, for
  # P1, drop whitespace).
  def reference_plain(kind, text, count, maxval)
    text = text.b.gsub(/#[^\r\n]*/, "")
    return text.delete(" \t\n\v\f\r").byteslice(0, count).bytes.map { |bit| (bit == 0x31) ? 0 : 255 } if kind == :p1

    samples = reference_gray(text.split(" ").first(count).map(&:to_i), maxval)
    (kind == :p3) ? samples.each_slice(3).map { |rgb| lum(*rgb) } : samples
  end

  # Raster text with +count+ samples, varied separators, leading zeros and comments: glued to a sample,
  # CR-terminated, empty, and a few longer than a chunk. P1 bits are sometimes unseparated.
  def random_plain_text(rng, count, maxval, bits:)
    text = +""
    count.times do
      text <<
        if bits
          rng.rand(2).to_s
        else
          zeros = rng.rand(12).zero? ? rng.rand(4) : 0
          "0" * zeros + rng.rand(maxval + 1).to_s
        end
      text <<
        if rng.rand(count) < 3
          " ##{"y" * (64 * 1024 + rng.rand(20_000))}\n"
        else
          case rng.rand(40)
          when 0 then "#glued comment #{"x" * rng.rand(300)}\n"
          when 1 then " # CR-terminated\r"
          when 2 then "\r\n#\n"
          when 3 then "\t\v\f "
          when 4 then "\n"
          else (bits && rng.rand(3).zero?) ? "" : " "
          end
        end
    end
    text
  end

  # The block's result and the largest String or Array returned by any method while it runs, except +input+
  # (which the decoder returns as is when checking its encoding) and the decoded pixels.
  def largest_temporary(input)
    require "objspace"
    sizes = Hash.new(0)
    trace = TracePoint.new(:c_return, :return) do |point|
      value = point.return_value
      next unless value.is_a?(String) || value.is_a?(Array)
      next if value.equal?(input)

      size = ObjectSpace.memsize_of(value)
      next if size < 64 * 1024

      id = value.object_id
      sizes[id] = size if size > sizes[id]
    end
    result = trace.enable { yield }
    sizes.delete(result.pixels.object_id) if result.is_a?(Pnm::Decoded)
    [result, sizes.values.max || 0]
  end

  # An IO serving +data+ followed by an endless run of NUL bytes that is never materialized. Reading more
  # than +budget+ bytes in total fails the test at once.
  class TailIO
    attr_reader :bytes_read

    def initialize(data, budget:)
      @data = data.b
      @budget = budget
      @bytes_read = 0
    end

    def read(length = nil)
      raise ArgumentError, "unbounded read of an endless IO" if length.nil?
      if @bytes_read + length > @budget
        raise Minitest::Assertion, "read up to byte #{@bytes_read + length}, past the #{@budget}-byte budget"
      end

      chunk = @data.byteslice(@bytes_read, length) || "".b
      chunk << "\0" * (length - chunk.bytesize)
      @bytes_read += length
      chunk
    end
  end

  # An IO whose reads return at most 1000 bytes (like a socket's), in UTF-8 as a text-mode File would.
  class ShortReadIO
    def initialize(data)
      @data = data.b
      @position = 0
    end

    def read(length)
      return nil if @position >= @data.bytesize

      chunk = @data.byteslice(@position, [length, 1000].min)
      @position += chunk.bytesize
      chunk.force_encoding(Encoding::UTF_8)
    end
  end
end
