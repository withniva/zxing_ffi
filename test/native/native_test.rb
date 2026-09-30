# frozen_string_literal: true

require "test_helper"
require "open3"
require "rbconfig"

# Optional symbols, ownership helpers, enum values.
class NativeTest < Minitest::Test
  NATIVE = ZXingFFI::Native

  def setup
    require_native!
  end

  # Values copied from ZXingC.h (3.1.1). A mismatch means the header changed: re-verify the bindings.
  def test_enum_values_match_the_header
    image_format = NATIVE.enum_type(:image_format)
    assert_equal 0, image_format[:none]
    assert_equal 0x01000000, image_format[:lum]
    assert_equal 0x02000000, image_format[:lum_a]
    assert_equal 0x03000102, image_format[:rgb]
    assert_equal 0x03020100, image_format[:bgr]
    assert_equal 0x04000102, image_format[:rgba]
    assert_equal 0x04010203, image_format[:argb]
    assert_equal 0x04020100, image_format[:bgra]
    assert_equal 0x04030201, image_format[:abgr]

    assert_equal [0, 1, 2, 3], %i[local_average global_histogram fixed_threshold bool_cast].map { NATIVE.enum_type(:binarizer)[_1] }
    assert_equal [0, 1, 2], %i[ignore read require].map { NATIVE.enum_type(:ean_add_on_symbol)[_1] }
    assert_equal [0, 1, 2, 3, 4, 5], %i[plain eci hri escaped hex hex_eci].map { NATIVE.enum_type(:text_mode)[_1] }
    assert_equal [0, 1, 2, 3, 4, 5], %i[text binary mixed gs1 iso15434 unknown_eci].map { NATIVE.enum_type(:content_type)[_1] }
    assert_equal [0, 1, 2, 3], %i[none format checksum unsupported].map { NATIVE.enum_type(:error_type)[_1] }
  end

  def test_position_struct_layout
    assert_equal 8, ZXingFFI::Native::PointI.size
    assert_equal 32, ZXingFFI::Native::Position.size
    assert_equal [0, 8, 16, 24], %i[top_left top_right bottom_right bottom_left].map { ZXingFFI::Native::Position.offset_of(_1) }
  end

  def test_version_and_library_info
    library = NATIVE.load!

    assert_same library, NATIVE.load!, "load! must be idempotent"
    assert NATIVE.loaded?
    assert_equal library.version, NATIVE.ZXing_Version
    assert ZXingFFI::LibraryLoader.supported_version?(library.version)
  end

  def test_optional_features_match_exported_symbols
    exported = FFI::DynamicLibrary.open(NATIVE.library.path, FFI::DynamicLibrary::RTLD_LAZY)
    expectations = {
      try_denoise: "ZXing_ReaderOptions_setTryDenoise",
      rotation: "ZXing_Barcode_rotation",
      image_view_new_checked: "ZXing_ImageView_new_checked"
    }
    expectations.each do |feature, symbol|
      assert_equal !exported.find_function(symbol).nil?, NATIVE.supports?(feature), "supports?(#{feature.inspect})"
    end
    assert_equal expectations.keys.select { |f| NATIVE.supports?(f) }, NATIVE.optional_features
  end

  def test_supports_rejects_unknown_features
    assert_raises(ArgumentError) { NATIVE.supports?(:time_travel) }
  end

  def test_take_string_copies_frees_and_handles_null
    assert_nil NATIVE.take_string(FFI::Pointer::NULL)
    assert_nil NATIVE.take_string(nil)

    value = ZXingFFI::Formats.meta.fetch(:all_linear)
    name = NATIVE.take_string(NATIVE.ZXing_BarcodeFormatToString(value))
    assert_equal "All Linear", name
    assert_equal Encoding::UTF_8, name.encoding
  end

  def test_take_formats_reads_int_arrays
    all = NATIVE.take_formats { |count| NATIVE.ZXing_BarcodeFormatsList(ZXingFFI::Formats.meta.fetch(:all), count) }

    assert_kind_of Array, all
    assert_operator all.size, :>=, 30
    assert all.all?(Integer)
  end

  def test_last_error_message_is_set_by_a_failure_and_cleared_by_reading
    NATIVE.last_error_message # clear anything left over
    assert_nil NATIVE.last_error_message

    ptr = NATIVE.take_formats { |count| NATIVE.ZXing_BarcodeFormatsFromString("definitely not a format", count) }
    assert_nil ptr
    assert_match(/not a valid barcode format/i, NATIVE.last_error_message)
    assert_nil NATIVE.last_error_message
  end

  def test_last_error_message_is_thread_local
    NATIVE.ZXing_BarcodeFormatFromString("nope nope")
    other_thread = Thread.new { NATIVE.last_error_message }.value

    assert_nil other_thread, "another thread must not see this thread's error"
    refute_nil NATIVE.last_error_message
  end

  def test_try_denoise_unavailable_raises_not_supported
    # Exercise the "symbol absent" path regardless of which library is loaded.
    with_feature(:try_denoise, false) do
      image = ZXingFFI::SyntheticImages.qr_image
      assert_raises(ZXingFFI::NotSupported) { ZXingFFI.read(image, try_denoise: true) }
      assert_equal 1, ZXingFFI.read(image, try_denoise: false).size
    end
  end

  def test_try_denoise_when_available
    skip "library built without ZXING_EXPERIMENTAL_API" unless NATIVE.supports?(:try_denoise)

    results = ZXingFFI.read(ZXingFFI::SyntheticImages.qr_image, try_denoise: true)
    assert_equal [ZXingFFI::SyntheticImages::QR_TEXT], results.map(&:text)
  end

  def test_rotation_falls_back_to_orientation
    with_feature(:rotation, false) do
      barcode = ZXingFFI.read(ZXingFFI::SyntheticImages.qr_image).first
      assert_equal 0, barcode.rotation
    end
  end

  # Homebrew's zxing-cpp is built without the experimental API: check the real "absent" path when present.
  def test_homebrew_library_without_experimental_api
    path = "/opt/homebrew/lib/libZXing.dylib"
    skip "no Homebrew libZXing" unless File.exist?(path)

    script = <<~RUBY
      require "zxing_ffi"
      puts ZXingFFI::Native.supports?(:try_denoise)
      image = ZXingFFI::Image.new(("\\xFF".b * 64), width: 8, height: 8)
      begin
        ZXingFFI.read(image, try_denoise: true)
      rescue ZXingFFI::NotSupported => e
        puts "NotSupported"
      end
    RUBY
    out, status = Open3.capture2e({"ZXING_LIB" => path}, RbConfig.ruby, "-I", File.expand_path("../../lib", __dir__), "-e", script)

    assert status.success?, out
    skip "Homebrew library has the experimental API" if out.start_with?("true")
    assert_equal "false\nNotSupported\n", out
  end

  private

  def with_feature(feature, value)
    features = NATIVE.instance_variable_get(:@features)
    NATIVE.instance_variable_set(:@features, features.merge(feature => value).freeze)
    yield
  ensure
    NATIVE.instance_variable_set(:@features, features)
  end
end
