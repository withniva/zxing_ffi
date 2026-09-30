#!/bin/sh
# Installs a platform gem the way a user would, then scans fixtures with it (`rake gem:verify`, CI).
#
#   verify_gem.sh GEM_DIR PLATFORM
#
# GEM_DIR holds zxing_ffi-*.gem files: platform gems and optionally the ruby-platform gem. `gem install zxing_ffi`
# from an index of them must choose PLATFORM for this machine (so a wrong platform name, or a platform gem losing to
# the ruby gem, fails here). Then, from outside the repository, with ZXING_LIB and Bundler unset:
#   - zxing-scan decodes a PDF (Poppler) and a PNG (ImageMagick) fixture;
#   - the loaded libZXing is the file in the installed gem's vendor/lib, reported as "bundled" by the diagnostics;
#   - the license notices are installed next to it.
# On Linux (containers) Poppler and ImageMagick are installed first when missing, and the check fails if any
# libZXing exists on the system. On macOS the tools must be present; a Homebrew libZXing may exist (it must not be
# the one loaded).
set -eu

gems=$(cd "$1" && pwd)
platform=$2
root=$(cd "$(dirname "$0")/../.." && pwd)
fixtures="$root/test/fixtures"

fail() {
  echo "verify_gem: $platform: $*" >&2
  exit 1
}

unset ZXING_LIB RUBYOPT RUBYLIB BUNDLE_GEMFILE BUNDLE_BIN_PATH BUNDLER_SETUP BUNDLER_VERSION BUNDLE_PATH GEM_PATH

have() { command -v "$1" > /dev/null; }

if [ "$(uname -s)" = Linux ]; then
  # RHEL-family images (e.g. almalinux:8, the glibc 2.28 baseline) have no Ruby: take 3.3 from AppStream.
  if ! have ruby && [ "$(id -u)" = 0 ] && have dnf; then
    echo "verify_gem: installing Ruby 3.3 (AppStream module)"
    dnf module enable -y -q ruby:3.3 > /dev/null && dnf install -y -q ruby rubygems > /dev/null
  fi
  if ! have pdftoppm || ! { have magick || have convert; }; then
    [ "$(id -u)" = 0 ] || fail "poppler-utils and imagemagick are missing (run as root to install them)"
    echo "verify_gem: installing poppler-utils and imagemagick"
    if command -v apt-get > /dev/null; then
      apt_install() {
        apt-get update -qq > /dev/null &&
          DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends poppler-utils imagemagick > /dev/null
      }
      # End-of-life releases (Debian 11 since 2026-08) lose their security pool: retry from the main suites.
      apt_install || { sed -i '/debian-security/d' /etc/apt/sources.list && apt_install; }
    elif command -v apk > /dev/null; then
      apk add --no-cache -q poppler-utils imagemagick
    elif command -v dnf > /dev/null; then
      dnf install -y -q epel-release > /dev/null && dnf install -y -q poppler-utils ImageMagick > /dev/null
    else
      fail "no known package manager"
    fi
  fi
  system_libs=$(find / -xdev \( -path /proc -o -path "$root" -o -path "$gems" \) -prune -o -name 'libZXing*' -print 2> /dev/null | head -n 5)
  [ -z "$system_libs" ] || fail "a system libZXing exists: $system_libs"
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/zxing-verify.XXXXXX")
trap 'rm -rf "$work"' EXIT INT TERM
mkdir -p "$work/repo/gems" "$work/tools" "$work/home"
cp "$gems"/zxing_ffi-*.gem "$work/repo/gems/"

# GEM_DIR becomes a gem source with a real index, so RubyGems' resolver chooses among the platform variants exactly
# as it does on rubygems.org (`gem install --local DIR` would take the first gem of the right version instead).
# `gem generate_index` lives in a gem since RubyGems 3.5; it is installed into (and run from) a scratch GEM_HOME.
GEM_HOME="$work/tools" GEM_PATH="$work/tools" gem install --no-document --silent rubygems-generate_index
GEM_HOME="$work/tools" GEM_PATH="$work/tools" gem generate_index --silent --directory "$work/repo"

export GEM_HOME="$work/home" GEM_PATH="$work/home"
gem install --no-document --silent ffi --version '>= 1.16, < 2'   # the dependency, from rubygems.org
gem install --no-document --clear-sources --source "file://$work/repo/" zxing_ffi
gem list --exact zxing_ffi ffi

cd "$work"
expect() { # expect LABEL OUTPUT TEXT...
  label=$1 output=$2
  shift 2
  for text in "$@"; do
    printf '%s\n' "$output" | grep -qxF "$text" || fail "$label: '$text' not decoded (got: $output)"
  done
}
pdf=$("$GEM_HOME/bin/zxing-scan" --text-only "$fixtures/pdfs/vector_qr_code128_datamatrix.pdf") || fail "zxing-scan failed on the PDF"
expect PDF "$pdf" "https://example.com/zxf/vector/qr" "ZXF-VECTOR-128" "ZXF vector Data Matrix"
png=$("$GEM_HOME/bin/zxing-scan" --text-only "$fixtures/images/clean_png.png") || fail "zxing-scan failed on the PNG"
expect PNG "$png" "zxing_ffi/clean_png" "CLEAN-PNG"
echo "verify_gem: zxing-scan PDF: $(printf '%s' "$pdf" | tr '\n' '|'); PNG: $(printf '%s' "$png" | tr '\n' '|')"
"$GEM_HOME/bin/zxing-scan" --diagnose | grep -Eq '"source": *"bundled"' || fail "zxing-scan --diagnose does not report the bundled library"

ruby -e '
  require "zxing_ffi"
  platform = ARGV.fetch(0)
  spec = Gem.loaded_specs.fetch("zxing_ffi")
  abort "installed #{spec.full_name}, expected the #{platform} gem" unless spec.platform.to_s == platform
  found = ZXingFFI::Native.load!
  vendor = File.realpath(File.join(spec.gem_dir, "vendor", "lib"))
  abort "loaded #{found.path}, not the library bundled in #{vendor}" unless File.dirname(found.path) == vendor
  source = ZXingFFI.diagnostics.dig(:library, :source)
  abort "diagnostics report the library source as #{source.inspect}" unless source == :bundled
  %w[LICENSE-zxing-cpp.txt LICENSE-libzueci.txt NOTICE.txt].each do |name|
    abort "vendor/lib/#{name} is missing" unless File.file?(File.join(vendor, name))
  end
  puts "verify_gem: #{spec.full_name} OK on #{RUBY_PLATFORM} (Ruby #{RUBY_VERSION}): #{found.path}, zxing-cpp #{found.version}"
' "$platform"
