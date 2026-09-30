# frozen_string_literal: true

require "test_helper"

# ZXingFFI.read: options, pixel formats, crop, results, errors.
class ReaderTest < Minitest::Test
  IMAGES = ZXingFFI::SyntheticImages

  def setup
    require_native!
  end

  def test_reads_a_qr_code
    results = ZXingFFI.read(IMAGES.qr_image)

    assert_equal 1, results.size
    barcode = results.first
    assert_equal IMAGES::QR_TEXT, barcode.text
    assert_equal IMAGES::QR_TEXT.b, barcode.bytes
    assert_equal Encoding::UTF_8, barcode.text.encoding
    assert_equal Encoding::BINARY, barcode.bytes.encoding
    assert_equal :qr_code, barcode.format
    assert_equal :qr_code, barcode.symbology
    assert_equal "QR Code", barcode.format_name
    assert_equal :text, barcode.content_type
    assert_equal "]Q1", barcode.symbology_identifier
    assert_equal 0, barcode.rotation
    assert barcode.valid?
    refute barcode.mirrored?
    refute barcode.inverted?
    refute barcode.eci?
    assert_nil barcode.error
    assert_nil barcode.sequence
    assert_nil barcode.page
    assert_nil barcode.pass
    assert_equal "M", barcode.extra["ECLevel"]
    assert_equal "1", barcode.extra["Version"]
  end

  def test_position_covers_the_symbol
    # 21 modules × 4 px + 4-module quiet zone (16 px) on each side
    barcode = ZXingFFI.read(IMAGES.qr_image(scale: 4, quiet: 4)).first
    quad = barcode.position

    assert_in_delta 16, quad.top_left.x, 2
    assert_in_delta 16, quad.top_left.y, 2
    assert_in_delta 16 + 84, quad.bottom_right.x, 2
    assert_in_delta 16 + 84, quad.bottom_right.y, 2
    assert quad.to_a.all? { |p| p.x.is_a?(Integer) && p.y.is_a?(Integer) }
  end

  def test_every_pixel_format_decodes_identically
    pixels, width, height = IMAGES.render
    expected = ZXingFFI.read(ZXingFFI::Image.new(pixels, width: width, height: height)).map(&:text)

    ZXingFFI::Image::BYTES_PER_PIXEL.each_key do |format|
      next if format == :lum

      image = ZXingFFI::Image.new(IMAGES.convert(pixels, format), width: width, height: height, format: format)
      assert_equal expected, ZXingFFI.read(image).map(&:text), "format #{format}"
    end
  end

  def test_row_stride_padding_is_respected
    pixels, width, height = IMAGES.render
    stride = width + 13
    padded = pixels.bytes.each_slice(width).map { |row| row.pack("C*") + ("\x00" * 13).b }.join

    image = ZXingFFI::Image.new(padded, width: width, height: height, row_stride: stride)
    assert_equal [IMAGES::QR_TEXT], ZXingFFI.read(image).map(&:text)
  end

  def test_inverted_code_uses_library_try_invert_default
    image = IMAGES.qr_image(invert: true, canvas: [180, 180], offset: [0, 0])
    results = ZXingFFI.read(image)

    if ZXingFFI::LIBRARY_DEFAULTS[:try_invert]
      assert_equal [IMAGES::QR_TEXT], results.map(&:text)
      assert results.first.inverted?
    end
    assert_empty ZXingFFI.read(image, try_invert: false)
    assert_equal [IMAGES::QR_TEXT], ZXingFFI.read(image, try_invert: true).map(&:text)
  end

  def test_empty_result_is_not_an_error
    assert_equal [], ZXingFFI.read(IMAGES.blank)
  end

  def test_formats_option_filters
    image = IMAGES.qr_image

    assert_empty ZXingFFI.read(image, formats: :ean_13)
    assert_empty ZXingFFI.read(image, formats: %i[code_128 data_matrix])
    assert_equal 1, ZXingFFI.read(image, formats: [:qr_code]).size
    assert_equal 1, ZXingFFI.read(image, formats: "QR Code").size
    assert_equal 1, ZXingFFI.read(image, formats: :all_matrix).size
    assert_empty ZXingFFI.read(image, formats: :all_linear)
  end

  def test_text_modes
    image = IMAGES.qr_image

    assert_equal IMAGES::QR_TEXT, ZXingFFI.read(image).first.text
    assert_equal IMAGES::QR_TEXT, ZXingFFI.read(image, text_mode: :hri).first.text
    assert_equal IMAGES::QR_TEXT.unpack1("H*").upcase.scan(/../).join(" "), ZXingFFI.read(image, text_mode: :hex).first.text
  end

  def test_crop_reads_a_region_and_reports_crop_relative_positions
    image = IMAGES.qr_image(canvas: [400, 300], offset: [200, 100])

    inside = ZXingFFI::Reader.read(image, {}, crop: [180, 80, 160, 160])
    assert_equal [IMAGES::QR_TEXT], inside.map(&:text)
    assert_in_delta 200 + 16 - 180, inside.first.position.top_left.x, 2
    assert_in_delta 100 + 16 - 80, inside.first.position.top_left.y, 2

    assert_empty ZXingFFI::Reader.read(image, {}, crop: [0, 0, 150, 300])
  end

  def test_crop_is_validated
    image = IMAGES.qr_image
    [[-1, 0, 10, 10], [0, 0, 0, 10], [0, 0, image.width + 1, 10], [1, 1, image.width, 1], [0, 0, 10], [0.5, 0, 1, 1]].each do |crop|
      assert_raises(ArgumentError, crop.inspect) { ZXingFFI::Reader.read(image, {}, crop: crop) }
    end
  end

  def test_unknown_options_raise
    error = assert_raises(ArgumentError) { ZXingFFI.read(IMAGES.qr_image, try_hardr: true) }
    assert_includes error.message, ":try_hardr"
    assert_includes error.message, "try_harder"
    assert_raises(ArgumentError) { ZXingFFI.read(IMAGES.qr_image, crop: [0, 0, 1, 1]) }
  end

  def test_option_values_are_validated
    image = IMAGES.qr_image
    {
      try_harder: "yes", try_rotate: 1, pure: :yes, return_errors: "false",
      binarizer: :otsu, text_mode: :utf8, ean_add_on: true,
      max_symbols: 0, min_line_count: 256, formats: :nope
    }.each do |key, value|
      assert_raises(ArgumentError, "#{key}: #{value.inspect}") { ZXingFFI.read(image, key => value) }
    end
  end

  def test_every_option_is_accepted
    image = IMAGES.qr_image
    options = {
      formats: %i[qr_code], try_harder: true, try_rotate: false, try_invert: false, try_downscale: false,
      pure: false, binarizer: :global_histogram, max_symbols: 3, min_line_count: 2, return_errors: true,
      validate_optional_checksum: false, text_mode: :escaped, ean_add_on: :read
    }
    options[:try_denoise] = false
    assert_equal [IMAGES::QR_TEXT], ZXingFFI.read(image, **options).map(&:text)
    %i[local_average fixed_threshold bool_cast].each do |binarizer|
      assert_equal 1, ZXingFFI.read(image, binarizer: binarizer).size, binarizer
    end
  end

  def test_pure_option_on_a_clean_symbol
    assert_equal [IMAGES::QR_TEXT], ZXingFFI.read(IMAGES.qr_image, pure: true).map(&:text)
  end

  def test_max_symbols_limits_results
    pixels, width, height = IMAGES.render
    double = pixels.bytes.each_slice(width).map { |row| (row + row).pack("C*") }.join
    image = ZXingFFI::Image.new(double, width: width * 2, height: height)

    assert_equal 2, ZXingFFI.read(image).size
    assert_equal 1, ZXingFFI.read(image, max_symbols: 1).size
  end

  def test_released_image_raises
    image = IMAGES.qr_image.release!
    assert_raises(ZXingFFI::Error) { ZXingFFI.read(image) }
  end

  def test_non_image_raises_type_error
    assert_raises(TypeError) { ZXingFFI.read("not an image") }
  end

  def test_image_view_failure_raises_decode_error_with_the_library_message
    skip "needs ZXing_ImageView_new_checked" unless ZXingFFI::Native.supports?(:image_view_new_checked)

    image = IMAGES.qr_image
    image.instance_variable_set(:@bytesize, 10) # lie about the buffer size: the checked constructor rejects it
    error = assert_raises(ZXingFFI::DecodeError) { ZXingFFI.read(image) }
    assert_match(/inconsistent|out of bounds/i, error.message)
    assert_nil ZXingFFI::Native.last_error_message
  end

  def test_options_object_is_reusable_and_merge_overrides
    options = ZXingFFI::Reader::Options.new(formats: :qr_code)

    assert options.frozen?
    assert_equal true, options[:validate_optional_checksum]
    assert_equal :plain, options[:text_mode]
    merged = options.merge(text_mode: :hex, formats: nil)
    assert_equal :hex, merged[:text_mode]
    assert_nil merged.format_values
    assert_same options, options.merge({})
    3.times { assert_equal 1, ZXingFFI::Reader.read(IMAGES.qr_image, options).size }
  end

  def test_library_defaults_are_read_from_the_library
    defaults = ZXingFFI::LIBRARY_DEFAULTS

    assert defaults.frozen?
    %i[try_harder try_rotate try_invert try_downscale pure return_errors validate_optional_checksum].each do |key|
      assert_includes [true, false], defaults.fetch(key), key
    end
    assert_includes %i[local_average global_histogram fixed_threshold bool_cast], defaults.fetch(:binarizer)
    assert_includes %i[plain eci hri escaped hex hex_eci], defaults.fetch(:text_mode)
    assert_operator defaults.fetch(:max_symbols), :>=, 1
    assert_equal [], defaults.fetch(:formats), "empty format list means every format"
    assert_equal ZXingFFI::Native.supports?(:try_denoise), defaults.key?(:try_denoise)
    assert_equal defaults, ZXingFFI::Reader.library_defaults
  end

  def test_gem_defaults
    assert_equal({formats: :all, validate_optional_checksum: true, text_mode: :plain, return_errors: false}, ZXingFFI::Reader::GEM_DEFAULTS)
  end
end
