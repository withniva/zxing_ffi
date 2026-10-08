# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

# Prefer the library built by `rake zxing:build` unless ZXING_LIB is set explicitly
# (set ZXING_LIB="" to force system discovery instead).
unless ENV.key?("ZXING_LIB")
  vendored = %w[libZXing.dylib libZXing.so]
    .map { |name| File.expand_path("../vendor/zxing/lib/#{name}", __dir__) }
    .find { |path| File.exist?(path) }
  ENV["ZXING_LIB"] = vendored if vendored
end
ENV.delete("ZXING_LIB") if ENV["ZXING_LIB"] == ""

require "zxing_ffi"
require "minitest/autorun"
require "fileutils"
require "tmpdir"
require_relative "support/synthetic_images"

module ZXingFFI
  # Helpers shared by every test suite.
  module TestSupport
    ROOT = File.expand_path("..", __dir__)
    FIXTURES = File.join(ROOT, "test", "fixtures")

    class << self
      # Whether a compatible libZXing can be loaded (memoized).
      def native_available?
        return @native_available if defined?(@native_available)

        @native_available =
          begin
            ZXingFFI::Native.load!
            true
          rescue ZXingFFI::LibraryNotFound, ZXingFFI::IncompatibleLibrary
            false
          end
      end

      # Absolute path of an executable on PATH, or nil.
      def which(command)
        return command if command.include?(File::SEPARATOR) && File.executable?(command)

        ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |dir|
          path = File.join(dir, command)
          return path if File.file?(path) && File.executable?(path)
        end
        nil
      end

      # Tools the environment promises (ZXING_EXPECT_TOOLS=poppler,vips,image_magick).
      def expected_tools
        ENV.fetch("ZXING_EXPECT_TOOLS", "").split(",").map { |t| t.strip.to_sym }
      end
    end

    # Path inside test/fixtures.
    def fixture_path(*parts)
      File.join(FIXTURES, *parts)
    end

    # Binary contents of a fixture.
    def fixture_bytes(*parts)
      File.binread(fixture_path(*parts))
    end

    # Skips unless libZXing is loadable. Fails instead when ZXING_REQUIRE_NATIVE is set (CI).
    def require_native!
      return if TestSupport.native_available?

      message = "libZXing not available (run `rake zxing:build` or set ZXING_LIB)"
      ENV["ZXING_REQUIRE_NATIVE"] ? flunk(message) : skip(message)
    end

    # Skips unless +available+ (or the block) is truthy. Fails instead when the environment
    # promises the tool via ZXING_EXPECT_TOOLS, so CI variants cannot silently skip.
    def require_tool!(name, available = nil)
      available = yield if block_given?
      return if available

      message = "#{name} not available"
      if TestSupport.expected_tools.include?(name.to_sym)
        flunk("#{message}, but ZXING_EXPECT_TOOLS includes it")
      else
        skip(message)
      end
    end

    # Asserts that two images have the same size and that no pixel byte differs by more than +tolerance+.
    def assert_pixels_within(tolerance, expected, actual, message = nil)
      assert_equal [expected.width, expected.height], [actual.width, actual.height], message
      worst = expected.to_bytes.bytes.zip(actual.to_bytes.bytes).map { |a, b| (a - b).abs }.max
      assert_operator worst, :<=, tolerance, message
    end

    # Runs the block inside a fresh temporary directory, removed afterwards.
    def in_tmpdir(&block)
      Dir.mktmpdir("zxing_ffi_test", &block)
    end

    # Temporarily sets environment variables (nil deletes).
    def with_env(vars)
      saved = vars.keys.to_h { |k| [k, ENV[k]] }
      vars.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
      yield
    ensure
      saved&.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    end

    # Minitest lifecycle hook: never leak configuration between tests.
    def after_teardown
      ZXingFFI.reset_config!
      super
    end
  end
end

Minitest::Test.include(ZXingFFI::TestSupport)
