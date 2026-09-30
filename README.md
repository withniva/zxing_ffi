# zxing_ffi

Read QR codes and every other barcode [zxing-cpp](https://github.com/zxing-cpp/zxing-cpp) understands from images and
PDFs, in any orientation, from Ruby.

```ruby
require "zxing_ffi"

ZXingFFI.scan("invoice.pdf").each do |barcode|
  puts "page #{barcode.page}: #{barcode.format} #{barcode.text}"
end
# page 1: qr_code https://example.com/invoices/2026-0042
```

The gem binds the zxing-cpp **C API through the `ffi` gem** (no compiler needed to install) and wraps it in a
pipeline: detect the input type by its magic bytes, turn every page or frame into a normalized 8-bit grayscale bitmap
(EXIF orientation, alpha, 16-bit, CMYK, fax resolutions, PDF `/Rotate` and CropBox all handled), run an escalating
sequence of decode passes, map results back to page coordinates, then deduplicate and order them. It replaces the
unmaintained `zbar` gem.

Supported inputs: PDF (born-digital and scanned), PNG, JPEG, TIFF (multi-page, fax), GIF, BMP, WebP, HEIF/AVIF (when
a loader supports them) and PNM. Symbologies: QR, Micro QR, rMQR, Data Matrix, Aztec, PDF417 (incl. Compact/Micro),
MaxiCode, Code 128, Code 39/93/32, Codabar, ITF, EAN/UPC, DataBar (all variants), Telepen, PZN, DX Film Edge — call
`ZXingFFI.formats` for the exact list your library supports.

## Requirements

- Ruby ≥ 3.3 (CRuby only; JRuby and TruffleRuby are not supported)
- **libZXing 3.1+ built with the C API** (the only hard native requirement)
- For PDFs: Poppler's command-line tools (`pdfinfo`, `pdftoppm`; `pdfimages` optional)
- For images: libvips with the `ruby-vips` gem (preferred) or ImageMagick; PNM needs nothing

### Installing libZXing 3.x

On x86_64/aarch64 Linux (glibc or musl) and macOS, `gem install zxing_ffi` gets a
[prebuilt platform gem](#prebuilt-platform-gems) that bundles libZXing, and this step can be skipped. Elsewhere:

Distribution packages often ship zxing-cpp 2.x, whose C API is incompatible. Check with `zxing-scan --diagnose`.

**macOS (Homebrew):**

```sh
brew install zxing-cpp poppler vips imagemagick
gem install zxing_ffi ruby-vips
```

Homebrew's library is found automatically (`/opt/homebrew/lib`).

**Ubuntu / Debian:** build the pinned release from source (needs `cmake` and a C++20 compiler). Ruby ≥ 3.3 is
required; Ubuntu 24.04's `ruby` package is 3.2, so install a newer Ruby first (e.g. with mise or rbenv).

```sh
sudo apt-get update
sudo apt-get install -y git cmake g++ poppler-utils libvips-tools imagemagick
sudo apt-get install -y libheif-plugin-libde265  # HEIC photos: libheif only suggests its HEVC decoder
git clone https://github.com/withniva/zxing_ffi && cd zxing_ffi
rake zxing:build            # downloads zxing-cpp 3.1.1, verifies its SHA-256, builds into vendor/zxing (no Bundler needed)
sudo cp -P vendor/zxing/lib/libZXing.so* /usr/local/lib && sudo ldconfig   # found automatically from now on
gem install zxing_ffi ruby-vips   # ruby-vips: in-process image loading with libvips
```

Instead of copying the library, `export ZXING_LIB=$(rake -s zxing:lib_path)` points at it inside the checkout (for the
current shell only). Until the gem is published on RubyGems, install it from the checkout:
`gem build zxing_ffi.gemspec && gem install ./zxing_ffi-*.gem`.

Or build it yourself with `cmake -DBUILD_SHARED_LIBS=ON -DZXING_C_API=ON -DZXING_READERS=ON -DZXING_WRITERS=OFF` and
point `ZXING_LIB` at the resulting `libZXing.so`.

**Library discovery** tries, in order: `ZXingFFI.config.library_path` / `ENV["ZXING_LIB"]` (if set, nothing else is
tried), a library bundled with the gem, the dynamic loader's search path (`libZXing.so.4`, `libZXing.dylib`, …), then
`/opt/homebrew/lib` and `/usr/local/lib`. Versions outside `>= 3.1.0, < 4.0` raise `ZXingFFI::IncompatibleLibrary`.

### Prebuilt platform gems

For these platforms RubyGems installs a gem with a prebuilt libZXing in its `vendor/lib/` (zxing-cpp 3.1.1 with readers
and the C API, compiled from the checksum-verified release tarball), so no libZXing has to be installed. Poppler and
libvips or ImageMagick are still needed for PDFs and images. Until the first release is published, build them with
`rake gem:platform`.

| Platform gem | Runs on |
|---|---|
| `x86_64-linux-gnu`, `aarch64-linux-gnu` | glibc ≥ 2.28: Debian 10+, Ubuntu 20.04+, RHEL/AlmaLinux/Rocky 8+, Amazon Linux 2023 |
| `x86_64-linux-musl`, `aarch64-linux-musl` | musl: Alpine 3.18+ |
| `arm64-darwin` | macOS 11+ (Apple silicon) |
| `x86_64-darwin` | macOS 10.13+ (Intel) |

The Linux libraries link the C++ runtime statically and need only the C library; the macOS ones need only the
system's libc++. Everywhere else (other CPUs, older glibc) RubyGems picks the plain `ruby` gem, which uses a
system libZXing installed as described above.

- **Bundler** records platforms in `Gemfile.lock`. A lockfile created by a recent Bundler (2.6 checked) lists every
  platform the gems ship; for an older one, add those you deploy to, e.g.
  `bundle lock --add-platform x86_64-linux aarch64-linux-musl` (`x86_64-linux` resolves to the `-gnu` gem). A
  lockfile with only `ruby` gets the plain gem everywhere.
- **Override:** `ZXING_LIB` (or `config.library_path`) still wins over the bundled library, e.g. to use a newer
  zxing-cpp. `zxing-scan --diagnose` shows which library is loaded: `library.path` and `library.source` (`bundled`,
  `explicit`, `system` or `prefix`). A bundled library that cannot be loaded is skipped in favour of a system one.
- **Licenses:** the bundled library is zxing-cpp (Apache-2.0) and includes libzueci (BSD-3-Clause). Their notices
  are installed next to it: `vendor/lib/NOTICE.txt`, `LICENSE-zxing-cpp.txt` and `LICENSE-libzueci.txt`.

## Usage

### Scanning files

```ruby
ZXingFFI.scan("photo.heic", formats: %i[qr_code data_matrix])
ZXingFFI.scan(io, effort: :thorough, stop: :exhaustive, pages: 1..3, password: "secret")

ZXingFFI.scan_pages("batch.pdf", threads: 4) do |page|
  page.page            # 1-based
  page.barcodes        # Array<ZXingFFI::Barcode>, ordered top-to-bottom, left-to-right
  page.dpi             # render DPI (PDF)
  page.passes_run      # [:base, :global_binarizer]
  page.skipped_passes  # { rotated_45: "no transformer available" }
  page.duration        # seconds
end
```

`scan` returns every page's barcodes ordered by page, then position; `scan_pages` yields a `ZXingFFI::PageResult` per
page in page order (or returns an Enumerator). Inputs can be a path (`String`/`Pathname`), an IO, or a
`ZXingFFI::Image`.

| Option | Default | Meaning |
|---|---|---|
| `formats` | `:all` | symbols (`:qr_code`, `:ean_13`, …), library names (`"QR Code"`), meta-formats (`:all_linear`, `:all_matrix`) |
| `effort` | `:normal` | `:fast`, `:normal`, `:thorough` — which decode passes may run (see below) |
| `passes` | — | explicit ladder, e.g. `%i[base tiles]` (overrides `effort`) |
| `stop` | `:found` | stop escalating a page after the first pass that finds something; `:exhaustive`; or an Integer: stop once that many distinct codes are found **on the page** (a page with fewer runs every pass) |
| `dpi` | `:auto` | PDF render DPI: `:auto` uses a scan's native resolution (150–600) or 300 for born-digital pages |
| `max_dpi` | `600` | upper bound for automatic and high-resolution renders |
| `pages` | all | `Integer`, `Range` or `Array` of 1-based pages; pages outside the document are ignored |
| `password` | — | PDF user password (Poppler reads at most 32 bytes: longer ones raise `NotSupported`; use `loader: :vips` with `vips_block_untrusted = false`) |
| `threads` | `1` | pages processed in parallel (rendering subprocesses and decoding both run concurrently) |
| `on_page_error` | `:raise` | `:skip` records the exception in `PageResult#error` and continues |
| `loader` | config order | force a loader: `:poppler`, `:vips`, `:image_magick`, `:pnm` |
| `min_length` | `{}` | minimum text length per format, e.g. `{itf: 6}` |
| `timeout` | — | per-page budget in seconds: caps renders (re-renders get what is left) and stops escalation (the first pass always runs) |
| `instrument` | — | callable receiving `(event, payload)` for `:page_loaded`, `:pass_completed`, `:page_completed` |
| `max_pixels`, `max_pages` | config | per-call limits |

Every `ZXingFFI.read` option below is accepted too and applies to every pass.

### Effort levels and passes

| Pass | What it does | Effort |
|---|---|---|
| `base` | library defaults + your options | fast, normal, thorough |
| `inverted` | decodes a pixel-inverted copy for white-on-black codes (zxing-cpp's `try_invert` only covers 2D codes, so with it on this pass handles the linear formats) | normal, thorough |
| `global_binarizer` | global-histogram binarizer | normal, thorough |
| `high_res` | PDF re-rendered at 2× DPI; small rasters upscaled 2× | normal, thorough |
| `tiles` | overlapping 1024–1536 px tiles, no downscaling (tiny codes on big pages) | thorough |
| `rotated_45` | image rotated 45° for linear codes at odd angles (also covers 135°/225°/315°) | thorough |
| `denoise` | `try_denoise: true` (libZXing built with `ZXING_EXPERIMENTAL_API` only) | thorough |

2D codes are found at any rotation by the base pass; linear codes at 0/90/180/270 too.

### Barcode

```ruby
barcode.text                 # "https://…" (UTF-8)
barcode.bytes                # raw payload (BINARY) — authoritative for binary content
barcode.format               # :qr_code, :ean_13, :code_128, …
barcode.symbology            # family, e.g. :ean_upc for :ean_13
barcode.content_type         # :text, :binary, :mixed, :gs1, :iso15434, :unknown_eci
barcode.position             # ZXingFFI::Quad in base-image pixels (top_left, top_right, bottom_right, bottom_left)
barcode.page_position        # PDF only: points from the top-left of the displayed page (CropBox, after /Rotate)
barcode.rotation             # degrees clockwise, 0..359
barcode.page, barcode.pass, barcode.dpi
barcode.mirrored?, barcode.inverted?, barcode.eci?, barcode.valid?
barcode.sequence             # structured append {index:, size:, id:} or nil
barcode.extra                # symbology metadata, e.g. {"ECLevel" => "M", "Version" => "3"}
barcode.to_h                 # JSON-friendly (bytes Base64-encoded when not text)
```

### Decoding raw pixels

```ruby
image = ZXingFFI::Image.new(gray_bytes, width: 640, height: 480)            # also :rgb, :bgra, … and row_stride:
ZXingFFI.read(image, formats: :qr_code, try_harder: true)
image.release!                                                                # free the buffer early
```

`read` runs a single decode. Options map 1:1 to zxing-cpp's `ReaderOptions`: `formats`, `try_harder`, `try_rotate`,
`try_invert`, `try_downscale`, `try_denoise`, `pure`, `binarizer`, `max_symbols`, `min_line_count`, `return_errors`,
`validate_optional_checksum`, `text_mode` (`:plain`, `:eci`, `:hri`, `:escaped`, `:hex`, `:hex_eci`) and `ean_add_on`
(`:ignore`, `:read`, `:require`). Unset options keep the library's defaults (`ZXingFFI::LIBRARY_DEFAULTS`), except
that the gem defaults to `text_mode: :plain` and `validate_optional_checksum: true` — the latter drops Code 39 and ITF
symbols without a valid check digit, which avoids phantom reads on text and tables; pass
`validate_optional_checksum: false` if your labels carry no check digit.

### Command line

```
zxing-scan [options] FILE...
  -f, --formats LIST        comma-separated (default: all)
  -e, --effort LEVEL        fast|normal|thorough
      --stop MODE           found|exhaustive|N
      --dpi N|auto
  -p, --pages RANGE         e.g. 1-3,7
      --password PW         (also ZXING_PDF_PASSWORD)
  -j, --threads N
      --text-only           print text only, one per line
      --diagnose            print diagnostics JSON and exit
```

Output is JSON Lines, one object per barcode: `{file, page, format, text, bytes_b64?, content_type, position,
page_position, rotation, pass}`. Exit codes: 0 found, 1 none found, 2 usage error (checked before any file is
read), 3 processing error (reported on stderr per file; the remaining files are still scanned).

### Configuration

```ruby
ZXingFFI.configure do |c|
  c.library_path   = ENV["ZXING_LIB"]
  c.pdf_loaders    = %i[poppler vips]
  c.image_loaders  = %i[vips image_magick pnm]
  c.transformers   = %i[vips image_magick]
  c.default_dpi    = 300
  c.max_dpi        = 600
  c.max_pixels     = 64_000_000
  c.max_pages      = nil
  c.render_timeout = 60
  c.subprocess_memory_limit = 2 * 1024**3
  c.tool_paths     = {pdftoppm: "pdftoppm", pdfinfo: "pdfinfo", pdfimages: "pdfimages", magick: nil}
  c.vips_block_untrusted = true
end
```

Configuration is read at call time; don't change it while a scan is running. `ZXingFFI.diagnostics` (or
`zxing-scan --diagnose`) reports the library path and version, optional features, defaults, loaders, tools and
their versions.

## Limits and security

The gem is meant to process untrusted documents:

- **Renderers run in subprocesses** (Poppler, ImageMagick) with an argument array (never a shell), absolute paths,
  a timeout (`render_timeout`, process group killed with TERM then KILL), a cap on their output, and an address-space
  limit (`subprocess_memory_limit`, enforced on Linux only — macOS ignores `RLIMIT_AS`). Passwords are only ever passed
  as the argument after `-upw`.
- **Pixel cap**: every bitmap is checked against `max_pixels` before it is rendered or decoded. PDF pages that would
  exceed it are rendered at a lower (possibly fractional) DPI; rasters raise `ZXingFFI::LimitExceeded`.
- **No format confusion**: inputs are identified by magic bytes, never by extension. ImageMagick always reads with an
  explicit coder (`png:/path`), never sees PDF, PostScript, SVG, MVG, MSL or text, and gets special characters in
  paths neutralized. libvips is called with the loader for the sniffed type, and operations libvips flags as
  *untrusted* (in 8.18: `pdfload`, `magickload`, `ppmload`) are refused while `vips_block_untrusted` is true — so
  in-process PDF rendering with libvips is opt-in. A crash inside libvips or libZXing takes down the Ruby process.
- IO inputs are copied to a private (0600) temp file that is always removed.
- Decoding releases the GVL, so threads decode concurrently; results are identical to serial runs. Interrupts
  (`Thread#raise`, `Timeout`, signals) are delivered once the native decode has returned and its results are freed;
  leaving a threaded `scan` early stops the other page workers and kills their renderer processes.
- Passes after the first never lose results: if one fails (a re-render timing out, a transformer error), the page
  keeps what earlier passes found and `PageResult#skipped_passes` records `"failed: …"`. Passes whose image would
  exceed `max_pixels` (`high_res`, `rotated_45`) are skipped the same way.

Errors all inherit from `ZXingFFI::Error`: `LibraryNotFound`, `IncompatibleLibrary`, `NotSupported`,
`LoaderUnavailable`, `UnsupportedInput`, `PasswordRequired` (and `IncorrectPassword`), `RenderError` (`#stderr`,
`#exit_status`), `TimeoutError`, `LimitExceeded` (`#limit`, `#value`), `DecodeError`.

## Development

```sh
mise exec -- bundle install
mise exec -- bundle exec rake zxing:build   # vendor/zxing (the test helper points ZXING_LIB at it)
mise exec -- bundle exec rake               # all tests + standardrb
mise exec -- bundle exec rake test:unit     # also test:native, test:integration, test:corpus
mise exec -- bundle exec rake bench         # corpus benchmark → docs/benchmark.md with OUT=…
mise exec -- bundle exec script/generate_fixtures   # regenerate committed fixtures (zint, rqrcode, prawn, vips, magick, poppler)
mise exec -- bundle exec script/real_corpus         # real documents listed in real_corpus.local.yml → tmp/real_corpus (local only)
```

## Licensing

zxing_ffi is released under the [MIT License](LICENSE.txt). Third-party components: zxing-cpp is Apache-2.0 and the
prebuilt libZXing in the platform gems also contains libzueci (BSD-3-Clause); those gems ship both notices in
`vendor/lib/` (see [Prebuilt platform gems](#prebuilt-platform-gems)). Poppler (GPL) and ImageMagick are only run as
separate processes; libvips (LGPL) is loaded through your own `ruby-vips` installation.
