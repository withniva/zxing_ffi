# frozen_string_literal: true

require "test_helper"
require "ffi"

# Smoke test: proves the library named by ZXING_LIB loads with plain FFI and reports a 3.x version.
class LibrarySmokeTest < Minitest::Test
  module RawZXing
    extend FFI::Library
  end

  def test_zxing_lib_loads_and_reports_a_supported_version
    path = ENV["ZXING_LIB"]
    message = "ZXING_LIB not set (run `rake zxing:build`)"
    unless path
      ENV["ZXING_REQUIRE_NATIVE"] ? flunk(message) : skip(message)
    end

    RawZXing.ffi_lib(path)
    RawZXing.attach_function(:ZXing_Version, [], :string)
    version = RawZXing.ZXing_Version

    assert_match(/\A\d+\.\d+\.\d+/, version)
    assert_operator Gem::Version.new(version[/\A[\d.]+/]), :>=, Gem::Version.new("3.1.0")
    assert_operator Gem::Version.new(version[/\A[\d.]+/]), :<, Gem::Version.new("4.0")
  end
end
