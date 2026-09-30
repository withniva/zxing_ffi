# frozen_string_literal: true

# Prebuilt platform gems: each one bundles a portable libZXing in
# vendor/lib, so `gem install zxing_ffi` needs no system library.
#
#   rake gem:platforms                             # platforms, build environments, baselines
#   rake gem:platform PLATFORM=aarch64-linux-gnu   # -> pkg/zxing_ffi-<version>-aarch64-linux-gnu.gem
#   rake gem:verify PLATFORM=aarch64-linux-gnu     # install it in a clean container and scan fixtures with it
#
# PLATFORM may list several platforms, comma-separated. Linux libraries are compiled in containers (Docker; other
# architectures through QEMU emulation), macOS ones on a macOS host (x86_64 is cross-compiled on arm64). Environment:
#   DOCKER_RUN_ARGS="--cpus=4 --memory=6g"  extra `docker run` arguments, e.g. resource caps
#   JOBS=4                                  parallel compile jobs (default: the --cpus cap, else all CPUs)
#   FORCE=1                                 rebuild the library even when tmp/platform_gems/<platform>/ is current
#   IMAGE=ruby:3.3-slim-bullseye            container for gem:verify (Linux; default per platform below)
#
# The ruby-platform gem (`gem build zxing_ffi.gemspec`) does not change: platform gems are assembled from a copy of
# the gem's files in tmp/platform_gems/<platform>/gem/, never in the repository's vendor/lib.

require "digest"
require "fileutils"
require "json"
require "rubygems/package"
require "shellwords"
require "tmpdir"
require "zlib"

module PlatformGems
  ROOT = File.expand_path("..", __dir__)
  WORK = File.join(ROOT, "tmp", "platform_gems")
  PKG = File.join(ROOT, "pkg")
  SCRIPTS = "script/platform_gems"

  MANYLINUX = "quay.io/pypa/manylinux_2_28_%s:2026.09.23-1"
  ALPINE = "alpine:3.21"
  ALPINE_SETUP = "apk add --no-cache -q cmake make g++ binutils"

  # Linux: the C++ runtime is linked statically and its symbols are kept out of the dynamic symbol table.
  LINUX_LDFLAGS = "-static-libstdc++ -static-libgcc -Wl,--exclude-libs,ALL"

  # Build environment and baseline of one platform gem.
  # @!attribute arch [String] CPU as Docker (linux/<arch>) or CMAKE_OSX_ARCHITECTURES spells it
  Target = Data.define(:platform, :os, :arch, :image, :setup, :macos_min, :verify_image, :baseline)

  TARGETS = [
    Target.new(platform: "x86_64-linux-gnu", os: :linux, arch: "amd64", image: format(MANYLINUX, "x86_64"),
      setup: nil, macos_min: nil, verify_image: "ruby:3.4-slim", baseline: "glibc >= 2.28"),
    Target.new(platform: "aarch64-linux-gnu", os: :linux, arch: "arm64", image: format(MANYLINUX, "aarch64"),
      setup: nil, macos_min: nil, verify_image: "ruby:3.4-slim", baseline: "glibc >= 2.28"),
    Target.new(platform: "x86_64-linux-musl", os: :linux, arch: "amd64", image: ALPINE, setup: ALPINE_SETUP,
      macos_min: nil, verify_image: "ruby:3.4-alpine", baseline: "musl >= 1.2.4 (Alpine >= 3.18)"),
    Target.new(platform: "aarch64-linux-musl", os: :linux, arch: "arm64", image: ALPINE, setup: ALPINE_SETUP,
      macos_min: nil, verify_image: "ruby:3.4-alpine", baseline: "musl >= 1.2.4 (Alpine >= 3.18)"),
    Target.new(platform: "arm64-darwin", os: :darwin, arch: "arm64", image: nil, setup: nil, macos_min: "11.0",
      verify_image: nil, baseline: "macOS >= 11.0"),
    Target.new(platform: "x86_64-darwin", os: :darwin, arch: "x86_64", image: nil, setup: nil, macos_min: "10.13",
      verify_image: nil, baseline: "macOS >= 10.13")
  ].to_h { |t| [t.platform, t] }.freeze

  # Files written next to the library (the gem's vendor/lib), besides NOTICE-zxing-cpp*.txt when upstream has any.
  NOTICES = %w[NOTICE.txt LICENSE-zxing-cpp.txt LICENSE-libzueci.txt].freeze

  BSD_3_CLAUSE = <<~TEXT
    Redistribution and use in source and binary forms, with or without modification, are permitted provided that the
    following conditions are met:

    1. Redistributions of source code must retain the above copyright notice, this list of conditions and the
       following disclaimer.

    2. Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the
       following disclaimer in the documentation and/or other materials provided with the distribution.

    3. Neither the name of the copyright holder nor the names of its contributors may be used to endorse or promote
       products derived from this software without specific prior written permission.

    THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES,
    INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
    DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
    SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
    SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
    WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE
    USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
  TEXT

  module_function

  # @return [Array<Target>] the targets named by ENV["PLATFORM"] (comma-separated)
  def targets
    names = ENV.fetch("PLATFORM", "").split(",").map(&:strip).reject(&:empty?)
    abort "Set PLATFORM to one or more of: #{TARGETS.keys.join(", ")}" if names.empty?
    names.map { |name| TARGETS.fetch(name) { abort "Unknown PLATFORM #{name}; known: #{TARGETS.keys.join(", ")}" } }
  end

  def out_dir(target) = File.join(WORK, target.platform)

  def lib_name(target) = (target.os == :darwin) ? "libZXing.dylib" : "libZXing.so"

  def built_lib(target) = File.join(out_dir(target), lib_name(target))

  def gem_version = gemspec.version.to_s

  def gem_path(target) = File.join(PKG, "zxing_ffi-#{gem_version}-#{target.platform}.gem")

  # The repository's gemspec, evaluated in the repository root (its file globs are relative).
  def gemspec
    @gemspec ||= Dir.chdir(ROOT) { Gem::Specification.load("zxing_ffi.gemspec") } or abort "cannot load zxing_ffi.gemspec"
  end

  # zxing:build's flags plus the portability flags; handed to script/platform_gems/build_libzxing.sh.
  def cmake_args(target)
    portable = ["-DCMAKE_SKIP_RPATH=ON"]
    portable += if target.os == :darwin
      ["-DCMAKE_OSX_ARCHITECTURES=#{target.arch}", "-DCMAKE_OSX_DEPLOYMENT_TARGET=#{target.macos_min}"]
    else
      ["-DCMAKE_SHARED_LINKER_FLAGS=#{LINUX_LDFLAGS}"]
    end
    ZXingBuild::CMAKE_FLAGS + portable
  end

  # Everything that determines the built library: when it changes, gem:platform rebuilds.
  def inputs(target)
    scripts = %w[build_libzxing.sh check_library.sh].to_h do |name|
      [name, Digest::SHA256.file(File.join(ROOT, SCRIPTS, name)).hexdigest]
    end
    {zxing: ZXingBuild.version, sha256: ZXingBuild.expected_sha256, cmake: cmake_args(target), image: target.image,
     setup: target.setup, scripts: scripts}
  end

  # Builds the portable library into tmp/platform_gems/<platform>/ unless it is current.
  # @return [String] path of the stripped, checked library
  def build_library(target)
    ZXingBuild.download # verified tarball; packaging reads the license files from it even when the library is current
    stamp = File.join(out_dir(target), "inputs.json")
    wanted = JSON.pretty_generate(inputs(target))
    if !ENV["FORCE"] && File.exist?(built_lib(target)) && File.exist?(stamp) && File.read(stamp) == wanted
      puts "#{target.platform}: libZXing is current (#{built_lib(target)}; FORCE=1 rebuilds)"
      return built_lib(target)
    end

    FileUtils.rm_rf(out_dir(target))
    FileUtils.mkdir_p(out_dir(target))
    (target.os == :darwin) ? build_on_macos(target) : build_in_container(target)
    File.write(stamp, wanted)
    built_lib(target)
  end

  def build_on_macos(target)
    abort "#{target.platform} is built on macOS (it cross-compiles x86_64 on arm64)" unless RUBY_PLATFORM.include?("darwin")
    run!("sh", File.join(ROOT, SCRIPTS, "build_libzxing.sh"), ZXingBuild.tarball, out_dir(target), *cmake_args(target))
    run!("sh", File.join(ROOT, SCRIPTS, "check_library.sh"), built_lib(target), target.platform, target.macos_min)
  end

  def build_in_container(target)
    tarball = "/tarballs/#{File.basename(ZXingBuild.tarball)}"
    script = ["set -e"]
    # Files created by root in the container stay deletable on Linux hosts.
    script << "trap 'chown -R #{Process.uid}:#{Process.gid} /out' EXIT" if RUBY_PLATFORM.include?("linux")
    script << target.setup if target.setup
    script << %(sh /src/#{SCRIPTS}/build_libzxing.sh "$@")
    script << "sh /src/#{SCRIPTS}/check_library.sh /out/#{lib_name(target)} #{target.platform}"
    docker_run(target, target.image,
      ["-v", "#{File.dirname(ZXingBuild.tarball)}:/tarballs:ro", "-v", "#{out_dir(target)}:/out"],
      "sh", "-c", script.join("\n"), "build", tarball, "/out", *cmake_args(target))
  end

  def docker_run(target, image, mounts, *command)
    extra = Shellwords.split(ENV.fetch("DOCKER_RUN_ARGS", ""))
    jobs = ENV["JOBS"] || extra.join(" ")[/--cpus[= ](\d+)/, 1]
    env = jobs ? ["-e", "JOBS=#{jobs}"] : []
    run!("docker", "run", "--rm", "--platform", "linux/#{target.arch}", *extra, *env, "-v", "#{ROOT}:/src:ro",
      *mounts, image, *command)
  end

  # Assembles the gem from a copy of the ruby-platform gem's files plus vendor/lib.
  # @return [String] path of the .gem in pkg/
  def package(target, lib)
    stage = File.join(out_dir(target), "gem")
    FileUtils.rm_rf(stage)
    files = gemspec.files.reject { |f| f.start_with?("vendor/") }
    files.each do |file|
      FileUtils.mkdir_p(File.dirname(File.join(stage, file)))
      FileUtils.cp(File.join(ROOT, file), File.join(stage, file), preserve: true)
    end
    vendor = File.join(stage, "vendor", "lib")
    FileUtils.mkdir_p(vendor)
    FileUtils.install(lib, File.join(vendor, lib_name(target)), mode: 0o755)
    bundled = [lib_name(target), *write_notices(target, vendor)]

    spec = gemspec.dup
    spec.platform = Gem::Platform.new(target.platform)
    spec.files = files + bundled.map { |name| "vendor/lib/#{name}" }
    built = Dir.chdir(stage) { Gem::Package.build(spec) }
    FileUtils.mkdir_p(PKG)
    FileUtils.mv(File.join(stage, built), gem_path(target))
    gem_path(target)
  end

  # Writes the license notices for the bundled library into +dir+, from the verified release tarball.
  # @return [Array<String>] file names
  def write_notices(target, dir)
    top = %r{\A[^/]+/}
    sources = tarball_files(%r{#{top}(LICENSE|NOTICE[^/]*|core/src/libzueci/zueci\.[ch])\z})
    find = ->(suffix) { sources.find { |name, _| name.end_with?(suffix) }&.last }
    license = find.call("/LICENSE") or abort "zxing-cpp's LICENSE is missing from #{ZXingBuild.tarball}"
    File.write(File.join(dir, "LICENSE-zxing-cpp.txt"), license)
    upstream_notices = sources.select { |name, _| File.basename(name).start_with?("NOTICE") }.map do |name, text|
      "NOTICE-zxing-cpp#{File.extname(name).then { |ext| ext.empty? ? ".txt" : ext }}".tap do |file|
        File.write(File.join(dir, file), text)
      end
    end
    File.write(File.join(dir, "LICENSE-libzueci.txt"),
      libzueci_license(find.call("/zueci.h").to_s, find.call("/zueci.c").to_s))
    File.write(File.join(dir, "NOTICE.txt"), notice(target, upstream_notices))
    NOTICES + upstream_notices
  end

  # @return [Hash{String => String}] contents of the tarball's regular files whose names match +pattern+
  def tarball_files(pattern)
    files = {}
    Zlib::GzipReader.open(ZXingBuild.tarball) do |gz|
      Gem::Package::TarReader.new(gz).each do |entry|
        files[entry.full_name] = entry.read.to_s if entry.file? && entry.full_name.match?(pattern)
      end
    end
    files
  end

  # libzueci's files carry only an SPDX tag, so the BSD-3-Clause text is reproduced with their copyright line, followed
  # by the MIT notice of the UTF-8 decoder embedded in zueci.c. Aborts if either changed upstream (re-check then).
  def libzueci_license(header, source)
    copyright = header[/^\s*(Copyright \(C\) \d{4}.*?)\s*$/, 1]
    unless copyright && header.include?("SPDX-License-Identifier: BSD-3-Clause")
      abort "core/src/libzueci/zueci.h no longer states BSD-3-Clause with a copyright line: re-check its license"
    end
    decoder = source[/^\s*(Copyright \(c\) 2008-2009 Bjoern Hoehrmann.*?for details\.)/m, 1] or
      abort "the UTF-8 decoder notice in core/src/libzueci/zueci.c changed: re-check its license"
    <<~TEXT
      libzueci (zxing-cpp's core/src/libzueci; https://sourceforge.net/projects/libzueci/), compiled into libZXing
      for ECI character-set conversion. SPDX-License-Identifier: BSD-3-Clause

      #{copyright}

      #{BSD_3_CLAUSE}
      ------------------------------------------------------------------------------------------------------------------

      zueci.c contains a UTF-8 decoder under the following notice:

      #{decoder.gsub(/^[ \t]+/, "")}
    TEXT
  end

  def notice(target, upstream_notices)
    toolchain = File.read(File.join(out_dir(target), "toolchain.txt")).lines.map { |l| "  #{l.strip}" }.join("\n")
    environment = target.image ? "container #{target.image}" : "macOS host, CMAKE_OSX_DEPLOYMENT_TARGET #{target.macos_min}"
    upstream = upstream_notices.empty? ? "The release contains no NOTICE file." : "Its NOTICE: #{upstream_notices.join(", ")}."
    runtime = if target.os == :darwin
      "- The library links the system's libc++ and libSystem dynamically."
    else
      "- The GNU C++ runtime (libstdc++, libgcc) is linked statically, which the GCC Runtime Library Exception\n  " \
        "permits without conditions. The C library (#{target.platform.end_with?("musl") ? "musl" : "glibc"}) is the system's."
    end
    <<~TEXT
      Bundled libZXing: zxing_ffi #{gem_version} (#{target.platform})

      #{lib_name(target)} in this directory is zxing-cpp #{ZXingBuild.version} (https://github.com/zxing-cpp/zxing-cpp),
      compiled from the release asset zxing-cpp-#{ZXingBuild.version}.tar.gz (SHA-256 #{ZXingBuild.expected_sha256})
      with readers and the C API enabled and writers disabled; baseline #{target.baseline}.
      Built in: #{environment}
      #{toolchain}

      Licenses of the code in the library:
      - zxing-cpp (including its librscpp headers): Apache License 2.0, see LICENSE-zxing-cpp.txt. #{upstream}
      - libzueci (core/src/libzueci): BSD 3-Clause, Copyright (C) 2022 gitlost; it contains a UTF-8 decoder under the
        MIT license, Copyright (c) 2008-2009 Bjoern Hoehrmann. See LICENSE-libzueci.txt.
      #{runtime}

      These notices cover the bundled library only.
    TEXT
  end

  # Checks the packaged gem: platform, exactly one library plus the notices under vendor/lib, the same Ruby files
  # as the ruby-platform gem, and the library bytes.
  def check_gem(target, gem, lib)
    package = Gem::Package.new(gem)
    spec = package.spec
    abort "#{gem}: platform is #{spec.platform}" unless spec.platform.to_s == target.platform
    vendored = spec.files.grep(%r{\Avendor/})
    libraries = vendored.grep(%r{/libZXing})
    missing = NOTICES.map { |name| "vendor/lib/#{name}" } - vendored
    abort "#{gem}: vendor/lib has #{libraries.inspect}, missing #{missing.inspect}" unless libraries.size == 1 && missing.empty?
    others = spec.files - vendored
    expected = gemspec.files.reject { |f| f.start_with?("vendor/") }
    abort "#{gem}: files differ from the ruby-platform gem's: #{(others - expected) | (expected - others)}" unless others.sort == expected.sort

    Dir.mktmpdir do |dir|
      package.extract_files(dir, libraries.first)
      packed = File.join(dir, libraries.first)
      abort "#{gem}: packed library differs from #{lib}" unless FileUtils.identical?(packed, lib)
      abort "#{gem}: packed library is not executable" unless File.executable?(packed)
    end
    puts format("%s: %s (%.1f MB), library %s (%.1f MB), %s", target.platform, File.basename(gem),
      File.size(gem) / 1e6, libraries.first, File.size(lib) / 1e6, target.baseline)
  end

  # Installs the gem like a user would and scans fixtures (script/platform_gems/verify_gem.sh). pkg/ is the gem
  # source, so RubyGems must pick this platform's gem among everything built there.
  def verify(target)
    abort "#{gem_path(target)} not found; run `rake gem:platform PLATFORM=#{target.platform}` first" unless File.exist?(gem_path(target))
    if target.os == :linux
      docker_run(target, ENV.fetch("IMAGE", target.verify_image), ["-v", "#{PKG}:/gems:ro"],
        "sh", "/src/#{SCRIPTS}/verify_gem.sh", "/gems", target.platform)
    elsif !RUBY_PLATFORM.include?("darwin")
      abort "#{target.platform} is verified on macOS"
    elsif RbConfig::CONFIG["host_cpu"].sub("aarch64", "arm64") == target.arch
      run!("sh", File.join(ROOT, SCRIPTS, "verify_gem.sh"), PKG, target.platform)
    elsif target.arch == "x86_64"
      verify_under_rosetta(target)
    else
      abort "#{target.platform} cannot be verified on an #{RbConfig::CONFIG["host_cpu"]} Mac"
    end
  end

  # No x86_64 Ruby on arm64 Macs: decode a fixture with the gem's library through a small x86_64 C program instead.
  def verify_under_rosetta(target)
    abort "Rosetta is not installed" unless system("arch", "-x86_64", "/usr/bin/true", err: File::NULL)
    Dir.mktmpdir do |dir|
      Gem::Package.new(gem_path(target)).extract_files(dir, "vendor/lib/*")
      lib = File.join(dir, "vendor", "lib", lib_name(target))
      run!("sh", File.join(ROOT, SCRIPTS, "check_library.sh"), lib, target.platform, target.macos_min)
      smoke = File.join(dir, "smoke")
      run!("cc", "-arch", target.arch, "-mmacosx-version-min=#{target.macos_min}", "-o", smoke,
        File.join(ROOT, SCRIPTS, "smoke.c"))
      output = IO.popen(["arch", "-#{target.arch}", smoke, lib, File.join(ROOT, "test/fixtures/images/clean_pgm.pgm")], &:read)
      puts output
      abort "#{target.platform}: smoke test failed" unless $?.success? && output.lines.map(&:chomp).include?("zxing_ffi/clean_pgm")
      puts "#{target.platform}: library decodes under Rosetta (the gem itself needs an x86_64 Ruby to verify fully)"
    end
  end

  def run!(*cmd)
    puts cmd.map { |arg| Shellwords.escape(arg.to_s.tr("\n", ";")) }.join(" ")
    system(*cmd.map(&:to_s), exception: true)
  end
end

namespace :gem do
  desc "List the platform gems with their build environments and baselines"
  task :platforms do
    PlatformGems::TARGETS.each_value do |t|
      where = t.image || "macOS host (minos #{t.macos_min})"
      puts format("%-20s %-50s %s", t.platform, where, t.baseline)
    end
  end

  desc "Build pkg/zxing_ffi-<version>-<PLATFORM>.gem bundling a portable libZXing (PLATFORM=a,b; see gem:platforms)"
  task :platform do
    PlatformGems.targets.each do |target|
      lib = PlatformGems.build_library(target)
      gem = PlatformGems.package(target, lib)
      PlatformGems.check_gem(target, gem, lib)
      puts "#{target.platform}: test with ZXING_LIB=#{File.join(PlatformGems.out_dir(target), "gem", "vendor", "lib", PlatformGems.lib_name(target))}"
    end
  end

  desc "Install pkg/zxing_ffi-*-<PLATFORM>.gem in a clean environment and scan fixtures with it (IMAGE=... on Linux)"
  task :verify do
    PlatformGems.targets.each { |target| PlatformGems.verify(target) }
  end
end
