#!/bin/sh
# Builds the portable libZXing bundled in a prebuilt platform gem (`rake gem:platform`).
#
#   build_libzxing.sh TARBALL OUT_DIR [CMAKE_ARG...]
#
# TARBALL is the zxing-cpp release asset, already checksum-verified by `rake gem:platform`. The CMake arguments
# (zxing:build's flags plus the portability flags) come from rakelib/platform_gems.rake, so they live in one place.
# Only the ZXing library target is built. Result: OUT_DIR/libZXing.so (Linux) or OUT_DIR/libZXing.dylib (macOS),
# a single stripped file, plus OUT_DIR/toolchain.txt. Runs in the Linux build containers and on the macOS host.
# JOBS sets the build parallelism (default: all CPUs).
set -eu

tarball=$1
out=$2
shift 2

jobs=${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu)}
work=$(mktemp -d "${TMPDIR:-/tmp}/zxing-build.XXXXXX")
trap 'rm -rf "$work"' EXIT INT TERM

tar -xzf "$tarball" -C "$work"
src=$(dirname "$(ls "$work"/*/CMakeLists.txt | head -n 1)")

# As in `rake zxing:build`: ZXING_C_API adds a test program whose configure step git-clones stb, unpinned.
# An existing STB_IMAGE_INCLUDE_DIR skips the download; building only the ZXing target never compiles the program.
cmake -S "$src" -B "$work/build" "$@" -DSTB_IMAGE_INCLUDE_DIR="$src"
cmake --build "$work/build" --target ZXing --parallel "$jobs"
if [ -d "$work/build/_deps" ]; then
  echo "build_libzxing: CMake downloaded dependencies ($(ls "$work/build/_deps" | tr '\n' ' '))" >&2
  exit 1
fi

# The real file behind the libZXing.so -> .so.4 -> .so.3.1.1 (or .dylib) symlink chain.
real=$(find "$work/build/core" -maxdepth 1 -type f -name 'libZXing*' | head -n 1)
[ -n "$real" ] || { echo "build_libzxing: no libZXing in $work/build/core" >&2; exit 1; }

mkdir -p "$out"
case "$(uname -s)" in
  Darwin)
    lib="$out/libZXing.dylib"
    cp "$real" "$lib"
    strip -x "$lib"                    # local symbols only; the exported API stays
    codesign --force --sign - "$lib"   # strip invalidates the linker's ad-hoc signature (required on arm64)
    ;;
  *)
    lib="$out/libZXing.so"
    cp "$real" "$lib"
    strip --strip-unneeded "$lib"
    ;;
esac

# Recorded in the gem's vendor/lib/NOTICE.txt.
{
  echo "compiler: $(c++ --version | head -n 1)"
  echo "cmake: $(cmake --version | head -n 1)"
  case "$(uname -s)" in
    Darwin) echo "sdk: macOS $(xcrun --show-sdk-version)" ;;
    *) echo "libc: $( (ldd --version 2>&1 || true) | sed -n 's/^ldd (GNU libc) /glibc /p; s/^Version /musl /p' | head -n 1)" ;;
  esac
} > "$out/toolchain.txt"

echo "Built $lib ($(wc -c < "$lib" | tr -d ' ') bytes)"
