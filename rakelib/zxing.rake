# frozen_string_literal: true

# Builds the pinned zxing-cpp release into vendor/zxing.
#
#   rake zxing:build                      # pinned version
#   ZXING_VERSION=3.1.0 rake zxing:build  # another known release (CI tests the minimum supported one)
#   export ZXING_LIB=$(rake -s zxing:lib_path)
#
# Uses the release asset tarball (zxing-cpp-<ver>.tar.gz), not GitHub's auto-generated source archive.

require "digest"
require "etc"
require "fileutils"
require "open-uri"

module ZXingBuild
  PINNED_VERSION = "3.1.1"

  # SHA-256 of the zxing-cpp-<ver>.tar.gz release assets.
  CHECKSUMS = {
    "3.1.1" => "c3c02c29c0b519de7bd4e25b376e606e87f0761befd1282815642a2246613d14",
    "3.1.0" => "a3eb825154f05242283e7d94d8ebdcf95beb3a534eba393cce504e91c9b215bd"
  }.freeze

  # Also used by the platform gem builds (rakelib/platform_gems.rake). No flag may make the build download
  # anything: the docs directory fetches an unpinned stylesheet whenever Doxygen is found, hence the last flag.
  # (The C API's test program fetches stb with git; see `build` for how that is skipped.)
  CMAKE_FLAGS = %w[
    -DCMAKE_BUILD_TYPE=Release
    -DBUILD_SHARED_LIBS=ON
    -DZXING_C_API=ON
    -DZXING_READERS=ON
    -DZXING_WRITERS=OFF
    -DZXING_EXPERIMENTAL_API=ON
    -DZXING_EXAMPLES=OFF
    -DZXING_BLACKBOX_TESTS=OFF
    -DZXING_UNIT_TESTS=OFF
    -DZXING_PYTHON_MODULE=OFF
    -DCMAKE_INSTALL_LIBDIR=lib
    -DCMAKE_DISABLE_FIND_PACKAGE_Doxygen=ON
  ].freeze

  ROOT = File.expand_path("..", __dir__)

  module_function

  def version
    ENV.fetch("ZXING_VERSION", PINNED_VERSION)
  end

  def prefix
    ENV.fetch("ZXING_PREFIX", File.join(ROOT, "vendor", "zxing"))
  end

  def work_dir
    File.join(ROOT, "tmp", "zxing")
  end

  def tarball
    File.join(work_dir, "zxing-cpp-#{version}.tar.gz")
  end

  def url
    "https://github.com/zxing-cpp/zxing-cpp/releases/download/v#{version}/zxing-cpp-#{version}.tar.gz"
  end

  def stamp
    File.join(prefix, ".zxing-version")
  end

  def lib_path
    %w[libZXing.dylib libZXing.so].map { |n| File.join(prefix, "lib", n) }.find { |p| File.exist?(p) }
  end

  def built?
    File.exist?(stamp) && File.read(stamp).strip == version && lib_path
  end

  def expected_sha256
    CHECKSUMS.fetch(version) do
      ENV["ZXING_SHA256"] or
        abort "No known SHA-256 for zxing-cpp #{version}. Add it to CHECKSUMS or set ZXING_SHA256."
    end
  end

  def download
    FileUtils.mkdir_p(work_dir)
    unless File.exist?(tarball) && Digest::SHA256.file(tarball).hexdigest == expected_sha256
      puts "Downloading #{url}"
      URI.parse(url).open("rb") { |remote| File.binwrite(tarball, remote.read) }
    end
    actual = Digest::SHA256.file(tarball).hexdigest
    return if actual == expected_sha256

    FileUtils.rm_f(tarball)
    abort "SHA-256 mismatch for #{File.basename(tarball)}: expected #{expected_sha256}, got #{actual}"
  end

  def build
    src_root = File.join(work_dir, "src-#{version}")
    build_dir = File.join(work_dir, "build-#{version}")
    FileUtils.rm_rf([src_root, build_dir])
    FileUtils.mkdir_p(src_root)
    sh!("tar", "-xzf", tarball, "-C", src_root)
    source = Dir[File.join(src_root, "*", "CMakeLists.txt")].map { |f| File.dirname(f) }.first or
      abort "CMakeLists.txt not found in #{tarball}"

    # ZXING_C_API also defines a test program (ZXingCTest) whose configure step git-clones stb, unpinned, from
    # GitHub. Pointing STB_IMAGE_INCLUDE_DIR at an existing directory skips that download, and building only the
    # ZXing target never compiles the program. `cmake --install` still installs the library and headers.
    sh!("cmake", "-S", source, "-B", build_dir, *CMAKE_FLAGS, "-DSTB_IMAGE_INCLUDE_DIR=#{source}",
      "-DCMAKE_INSTALL_PREFIX=#{prefix}")
    sh!("cmake", "--build", build_dir, "--target", "ZXing", "--parallel", Etc.nprocessors.to_s)
    FileUtils.rm_rf(prefix)
    sh!("cmake", "--install", build_dir)
    File.write(stamp, "#{version}\n")
    puts "Installed zxing-cpp #{version} into #{prefix}"
    puts "export ZXING_LIB=#{lib_path}"
  end

  def sh!(*cmd)
    puts cmd.join(" ")
    system(*cmd, exception: true)
  end
end

namespace :zxing do
  desc "Download, verify, build and install zxing-cpp (#{ZXingBuild::PINNED_VERSION}) into vendor/zxing"
  task :build do
    if ZXingBuild.built? && !ENV["FORCE"]
      puts "zxing-cpp #{ZXingBuild.version} already built: #{ZXingBuild.lib_path} (FORCE=1 to rebuild)"
    else
      ZXingBuild.download
      ZXingBuild.build
    end
  end

  desc "Print the path of the built libZXing (for ZXING_LIB)"
  task :lib_path do
    path = ZXingBuild.lib_path or abort "libZXing not built; run `rake zxing:build`"
    puts path
  end

  desc "Remove vendor/zxing and build artifacts"
  task :clean do
    FileUtils.rm_rf([ZXingBuild.prefix, ZXingBuild.work_dir])
  end
end
