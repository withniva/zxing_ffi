# frozen_string_literal: true

require "test_helper"
require "json"
require "open3"
require "rbconfig"

# Library discovery, version gate, required symbols.
class LibraryLoaderTest < Minitest::Test
  LOADER = ZXingFFI::LibraryLoader

  def test_supported_version_gate
    assert LOADER.supported_version?("3.1.0")
    assert LOADER.supported_version?("3.1.1")
    assert LOADER.supported_version?("3.9.12")
    assert LOADER.supported_version?("3.1.1-dev")
    refute LOADER.supported_version?("3.0.2")
    refute LOADER.supported_version?("2.3.0")
    refute LOADER.supported_version?("4.0.0")
    refute LOADER.supported_version?("")
    refute LOADER.supported_version?("garbage")
  end

  def test_explicit_path_is_the_only_candidate
    assert_equal ["/nowhere/libZXing.so"], LOADER.candidates(explicit: "/nowhere/libZXing.so")
  end

  def test_discovery_candidates_include_system_names_and_existing_prefixed_paths
    candidates = LOADER.candidates(explicit: nil)

    assert_includes candidates, FFI.map_library_name("ZXing")
    assert_includes candidates, "libZXing.so.4"
    candidates.select { |c| c.start_with?("/") }.each { |path| assert File.exist?(path), path }
  end

  def test_bogus_explicit_path_raises_library_not_found_listing_attempts_and_help
    error = assert_raises(ZXingFFI::LibraryNotFound) { LOADER.find(explicit: "/nonexistent/libZXing.dylib") }

    assert_includes error.message, "/nonexistent/libZXing.dylib"
    assert_includes error.message, "Tried:"
    assert_includes error.message, "ZXING_LIB"
  end

  def test_bogus_zxing_lib_raises_library_not_found_on_first_use
    script = <<~RUBY
      require "zxing_ffi"
      begin
        ZXingFFI.formats
      rescue ZXingFFI::LibraryNotFound => e
        puts "LibraryNotFound"
        puts e.message
      end
    RUBY
    out, status = Open3.capture2e({"ZXING_LIB" => "/nonexistent/libZXing.so"}, RbConfig.ruby, "-I", lib_dir, "-e", script)

    assert status.success?, out
    assert_match(/\ALibraryNotFound\n/, out)
    assert_includes out, "/nonexistent/libZXing.so"
  end

  def test_diagnostics_report_a_missing_library_instead_of_raising
    script = 'require "zxing_ffi"; require "json"; puts JSON.generate(ZXingFFI.diagnostics[:library])'
    out, status = Open3.capture2e({"ZXING_LIB" => "/nonexistent/libZXing.so"}, RbConfig.ruby, "-I", lib_dir, "-e", script)

    assert status.success?, out
    library = JSON.parse(out.lines.last)
    refute library["loaded"]
    assert_match(/LibraryNotFound/, library["error"])
  end

  def test_finds_the_configured_library
    require_native!
    found = LOADER.find

    assert_equal ZXingFFI::Native.library.version, found.version
    assert File.exist?(found.path), found.path
    assert LOADER.supported_version?(found.version)
  end

  def test_rejects_a_library_with_an_unsupported_version
    path = fake_library("old", <<~C)
      const char* ZXing_Version(void) { return "2.3.0"; }
      void* ZXing_ReadBarcodes(void* a, void* b) { return 0; }
      void* ZXing_BarcodeFormatsFromString(const char* s, int* n) { return 0; }
    C
    error = assert_raises(ZXingFFI::IncompatibleLibrary) { LOADER.find(explicit: path) }

    assert_equal "2.3.0", error.version
    assert_includes error.message, "2.3.0"
  end

  def test_rejects_a_library_without_zxing_version
    path = fake_library("noversion", "int something_else(void) { return 1; }\n")
    error = assert_raises(ZXingFFI::IncompatibleLibrary) { LOADER.find(explicit: path) }

    assert_includes error.message, "ZXing_Version not exported"
  end

  def test_rejects_a_library_missing_required_symbols
    path = fake_library("partial", %(const char* ZXing_Version(void) { return "3.1.1"; }\n))
    error = assert_raises(ZXingFFI::IncompatibleLibrary) { LOADER.find(explicit: path) }

    assert_includes error.message, "ZXing_ReadBarcodes"
    assert_includes error.message, "ZXing_BarcodeFormatsFromString"
  end

  def test_accepts_a_minimal_library_with_a_supported_version_and_required_symbols
    path = fake_library("minimal", <<~C)
      const char* ZXing_Version(void) { return "3.4.0"; }
      void* ZXing_ReadBarcodes(void* a, void* b) { return 0; }
      void* ZXing_BarcodeFormatsFromString(const char* s, int* n) { return 0; }
    C
    found = LOADER.find(explicit: path)

    assert_equal "3.4.0", found.version
    assert_equal File.realpath(path), found.path
    assert_equal :explicit, found.source
  end

  # Platform gems: vendor/lib comes right after an explicit path, before any system library.
  def test_a_bundled_library_is_the_first_candidate_and_is_reported_as_bundled
    bundled = bundle_library_copy

    assert_equal bundled, LOADER.candidates(explicit: nil, bundled_dir: File.dirname(bundled)).first
    found = LOADER.find(explicit: nil, bundled_dir: File.dirname(bundled))

    assert_equal :bundled, found.source
    assert_equal File.realpath(bundled), found.path
  end

  def test_an_explicit_library_wins_over_a_bundled_one
    bundled = bundle_library_copy
    dir = File.dirname(bundled)

    assert_equal ["/nowhere/libZXing.so"], LOADER.candidates(explicit: "/nowhere/libZXing.so", bundled_dir: dir)
    found = LOADER.find(explicit: ZXingFFI::Native.load!.path, bundled_dir: dir)

    assert_equal :explicit, found.source
    assert_equal ZXingFFI::Native.load!.path, found.path
  end

  def test_an_unloadable_bundled_library_falls_back_to_the_system_search
    dir = Dir.mktmpdir("zxing_bundled")
    teardown_dirs << dir
    bogus = File.join(dir, FFI.map_library_name("ZXing"))
    File.binwrite(bogus, "not a shared library")

    begin
      found = LOADER.find(explicit: nil, bundled_dir: dir)
      refute_equal :bundled, found.source
    rescue ZXingFFI::LibraryNotFound => e
      assert_includes e.message, bogus
    end
  end

  # An installed platform gem: lib/ next to vendor/lib/, ZXING_LIB unset. The bundled copy must win over any
  # system or Homebrew library, and the diagnostics (zxing-scan --diagnose) must say so.
  def test_an_installed_gem_layout_loads_its_bundled_library
    gem_dir = Dir.mktmpdir("zxing_gem")
    teardown_dirs << gem_dir
    FileUtils.cp_r(lib_dir, File.join(gem_dir, "lib"))
    bundled = bundle_library_copy(File.join(gem_dir, "vendor", "lib"))
    script = 'require "zxing_ffi"; require "json"; puts JSON.generate(ZXingFFI.diagnostics[:library].slice(:path, :source))'
    out, status = Open3.capture2e({"ZXING_LIB" => nil}, RbConfig.ruby, "-I", File.join(gem_dir, "lib"), "-e", script)

    assert status.success?, out
    library = JSON.parse(out.lines.last)
    assert_equal "bundled", library["source"]
    assert_equal File.realpath(bundled), library["path"]
  end

  private

  # Copies the library under test into +dir+ (a fresh temporary directory by default) the way a platform gem ships it.
  def bundle_library_copy(dir = nil)
    require_native!
    dir ||= Dir.mktmpdir("zxing_bundled").tap { |d| teardown_dirs << d }
    FileUtils.mkdir_p(dir)
    File.join(dir, FFI.map_library_name("ZXing")).tap { |copy| FileUtils.cp(ZXingFFI::Native.load!.path, copy) }
  end

  def lib_dir
    File.expand_path("../../lib", __dir__)
  end

  # Compiles a tiny shared library exporting the given C source (skips without a C compiler).
  def fake_library(name, source)
    cc = ZXingFFI::TestSupport.which("cc") or skip("no C compiler")
    dir = Dir.mktmpdir("zxing_fake")
    teardown_dirs << dir
    src = File.join(dir, "#{name}.c")
    File.write(src, source)
    lib = File.join(dir, FFI.map_library_name("zxingfake_#{name}"))
    flags = RUBY_PLATFORM.include?("darwin") ? ["-dynamiclib"] : ["-shared", "-fPIC"]
    out, status = Open3.capture2e(cc, *flags, "-o", lib, src)
    skip("could not compile a test library: #{out}") unless status.success?
    lib
  end

  def teardown_dirs
    @teardown_dirs ||= []
  end

  def teardown
    teardown_dirs.each { |dir| FileUtils.rm_rf(dir) }
    super
  end
end
