# Changelog

## Unreleased

- **`high_res` pass**: rasters are upscaled with a centered bicubic (Catmull-Rom) filter instead of pixel
  replication, which kept the aliasing of codes rasterized at 1–2 px per module. QR codes at ~1.5 px per module
  that every pass missed are now found at `effort: :normal`. Both transformers' `resize` upscale this way at any
  scale above 1.

## 0.1.0 (2026-10-01)

First release candidate of `zxing_ffi`, a replacement for the unmaintained `zbar` gem.

- **Native core**: libZXing 3.1+ discovery (explicit `ZXING_LIB`, bundled, system, Homebrew/`/usr/local`) with a
  version gate; FFI bindings for the zxing-cpp C API (GVL released while decoding); runtime format map derived from
  the library; `ZXingFFI.read`, `ZXingFFI::Image`, `ZXingFFI::Barcode`, `ZXingFFI::LIBRARY_DEFAULTS`,
  `ZXingFFI.diagnostics`.
- **Inputs**: magic-byte sniffing; loaders for PDF (Poppler subprocesses, CropBox-accurate, password support,
  `dpi: :auto` from scan resolution), libvips (rasters; PDF opt-in), ImageMagick (rasters, IM7 or IM6) and PNM
  (pure Ruby); normalization of EXIF orientation, alpha, 16-bit, CMYK, palette, 1-bit and fax aspect ratios.
- **Pipeline**: effort levels and custom pass ladders (`base`, `inverted`, `global_binarizer`, `high_res`, `tiles`,
  `rotated_45`, `denoise`), stop modes, coordinate mapping back to page pixels and PDF points, deduplication,
  filtering, ordering, `scan` / `scan_pages` with threads, per-page errors and instrumentation.
- **Safety**: subprocess isolation with timeouts, output caps and memory limits; pixel caps (fractional DPI for
  absurd page sizes); no format confusion (explicit coders/loaders); untrusted libvips operations refused by default.
- **Robustness**: a failing escalation pass keeps earlier results (recorded in `skipped_passes`); malformed PDFs
  (zero or infinite page sizes) raise `RenderError`; interrupts never leak native results; threaded scans stop
  their workers on early exit; the pure-Ruby PNM decoder works in bounded memory.
- **CLI**: `zxing-scan` (JSON Lines, `--text-only`, `--diagnose`); one failing file does not stop the batch.
- **Tooling**: `rake zxing:build` (pinned, checksum-verified zxing-cpp), fixture generators, golden corpus test,
  `rake bench`.
- **Platform gems**: prebuilt gems bundling libZXing for x86_64/aarch64 Linux (glibc ≥ 2.28, musl) and macOS (arm64
  ≥ 11, x86_64 ≥ 10.13); diagnostics report `library.source` (`rake gem:platform`, `rake gem:verify`).
- **License**: MIT (`LICENSE.txt`, packed in every gem).
