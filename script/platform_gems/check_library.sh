#!/bin/sh
# Portability checks for the libZXing bundled in a platform gem (run by `rake gem:platform` after each build).
#
#   check_library.sh LIB PLATFORM [MACOS_MIN]
#
# Linux (needs GNU readelf; runs in the build container):
#   - right machine; no RPATH/RUNPATH; no debug sections;
#   - NEEDED only libc/libm/libpthread/libdl/ld-linux (glibc) or the musl libc;
#   - highest GLIBC_ symbol version <= MAX_GLIBC (default 2.28);
#   - no libstdc++/libgcc_s symbol versions and no C++ runtime symbols exported (statically linked and hidden);
#   - the C API is exported.
# macOS: single architecture, only /usr/lib/libc++ and libSystem linked, minos == MACOS_MIN, no LC_RPATH,
#   valid (ad-hoc) signature, C API exported.
set -eu

lib=$1
platform=$2
macos_min=${3:-}
max_glibc=${MAX_GLIBC:-2.28}

fail() {
  echo "check_library: $platform: $*" >&2
  exit 1
}

[ -f "$lib" ] || fail "$lib not found"

case "$platform" in
  *-linux-gnu | *-linux-musl)
    command -v readelf > /dev/null || fail "readelf not found"
    machine=$(readelf -h "$lib" | sed -n 's/^ *Machine: *//p')
    case "$platform:$machine" in
      x86_64-*:*X86-64* | aarch64-*:AArch64) ;;
      *) fail "machine is '$machine'" ;;
    esac

    dynamic=$(readelf -d "$lib")
    if echo "$dynamic" | grep -Eq '\((RPATH|RUNPATH)\)'; then fail "has an RPATH/RUNPATH"; fi
    needed=$(echo "$dynamic" | sed -n 's/.*(NEEDED).*\[\(.*\)\].*/\1/p')
    for name in $needed; do
      case "$platform:$name" in
        *-gnu:libc.so.6 | *-gnu:libm.so.6 | *-gnu:libpthread.so.0 | *-gnu:libdl.so.2 | *-gnu:ld-linux-*.so.*) ;;
        *-musl:libc.musl-*.so.1) ;;
        *) fail "unexpected NEEDED $name" ;;
      esac
    done

    if readelf -S -W "$lib" | grep -q '\.debug_'; then fail "not stripped (debug sections present)"; fi

    versions=$(readelf -V -W "$lib")
    if echo "$versions" | grep -Eq 'GLIBCXX_|CXXABI_|GCC_[0-9]'; then
      fail "references libstdc++/libgcc_s symbol versions (not statically linked)"
    fi
    glibc="none"
    if [ "${platform%-gnu}" != "$platform" ]; then
      glibc=$(echo "$versions" | grep -o 'GLIBC_[0-9][0-9.]*' | sed 's/^GLIBC_//' | sort -u -t. -k1,1n -k2,2n -k3,3n | tail -n 1)
      [ -n "$glibc" ] || fail "no GLIBC_ symbol versions found"
      newest=$(printf '%s\n%s\n' "$glibc" "$max_glibc" | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1)
      [ "$newest" = "$max_glibc" ] || fail "needs GLIBC_$glibc (> $max_glibc)"
    fi

    # Defined dynamic symbols: Num Value Size Type Bind Vis Ndx Name
    exported=$(readelf --dyn-syms -W "$lib" | awk '$7 != "UND" && ($5 == "GLOBAL" || $5 == "WEAK") { print $8 }')
    echo "$exported" | grep -qx 'ZXing_Version' || fail "ZXing_Version is not exported"
    runtime=$(echo "$exported" | grep -E '^(__cxa_|__gxx_personality|_Unwind_|_Znwm$|_ZdlPv$|_ZSt9terminatev$)' || true)
    [ -z "$runtime" ] || fail "exports C++ runtime symbols: $(echo "$runtime" | head -n 3 | tr '\n' ' ')"

    echo "check_library: $platform OK: machine $machine; NEEDED $(echo $needed); highest GLIBC $glibc"
    ;;

  *-darwin)
    arch=${platform%%-*}
    archs=$(lipo -archs "$lib")
    [ "$archs" = "$arch" ] || fail "architectures are '$archs', expected '$arch'"

    id=$(otool -D "$lib" | tail -n 1)
    deps=$(otool -L "$lib" | tail -n +2 | awk '{ print $1 }' | grep -vxF "$id" || true)
    for dep in $deps; do
      case "$dep" in
        /usr/lib/libc++.1.dylib | /usr/lib/libSystem.B.dylib) ;;
        *) fail "links $dep" ;;
      esac
    done

    loads=$(otool -l "$lib")
    if echo "$loads" | grep -q LC_RPATH; then fail "has an LC_RPATH"; fi
    # LC_BUILD_VERSION (minos X) or, for x86_64 targets below 10.14, LC_VERSION_MIN_MACOSX (version X).
    minos=$(echo "$loads" | awk '/cmd LC_BUILD_VERSION/ { b = 1 } /cmd LC_VERSION_MIN_MACOSX/ { v = 1 }
      b && $1 == "minos" { print $2; exit } v && $1 == "version" { print $2; exit }')
    [ -n "$minos" ] || fail "no deployment target load command"
    if [ -n "$macos_min" ] && [ "$minos" != "$macos_min" ]; then fail "minos is $minos, expected $macos_min"; fi

    codesign --verify "$lib" 2> /dev/null || fail "invalid code signature"
    nm -gU "$lib" | grep -q ' _ZXing_Version$' || fail "ZXing_Version is not exported"

    echo "check_library: $platform OK: $archs; minos $minos; links $(echo $deps)"
    ;;

  *) fail "unknown platform" ;;
esac
