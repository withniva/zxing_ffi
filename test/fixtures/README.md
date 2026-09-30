# Test fixtures

Everything here is **generated** by `script/generate_fixtures` (dev only) and committed. Real documents are never
committed (personal data): `script/real_corpus` builds a local corpus in `tmp/real_corpus/`
(gitignored) that the corpus test and `rake bench` include when present.

Encoders are independent of zxing-cpp so tests are not circular: `zint` for most symbologies, `rqrcode` for QR.
PDFs are built with Prawn (+ prawn-svg for vector codes), `qpdf`/`tiff2pdf`/`jbig2` for scans, rotation and encryption.

| Directory | Contents | Index |
|---|---|---|
| `symbologies/` | one clean 8-bit PGM per readable symbology and payload variant (native tests) | `symbologies/index.yml` |
| `images/` | raster corpus: formats, rotations, EXIF, alpha, 16-bit, CMYK, palette, fax, multi-page, inverted… | `manifest.d/images.yml` |
| `pdfs/` | PDF corpus: vector, embedded, scanned (JPEG/G4/JBIG2), /Rotate, encrypted, huge page, no-barcode pages | `manifest.d/pdfs.yml` |
| `samples/` | recorded tool output (`pdfinfo`, `pdfimages -list`, …) for parser unit tests | — |

`manifest.yml` is the concatenation of `manifest.d/*.yml` (rebuild with `script/generate_fixtures --manifest`).

## Symbol names

Our format symbols come from the library's human-readable names: downcase, non-alphanumerics → `_`, squeeze.
For zxing-cpp 3.1.1: `codabar code_39 code_39_standard code_39_extended code_32 pharmazentralnummer code_93 code_128
itf itf_14 databar databar_omni databar_stacked databar_stacked_omni databar_limited databar_expanded
databar_expanded_stacked ean_upc ean_13 ean_8 ean_5 ean_2 isbn upc_a upc_e telepen telepen_alpha telepen_numeric
other_barcode dx_film_edge pdf417 compact_pdf417 micropdf417 aztec aztec_code aztec_rune qr_code qr_code_model_1
qr_code_model_2 micro_qr_code rmqr_code data_matrix maxicode`.
Symbology families (what `Barcode#symbology` returns) are the entries without a variant, e.g. `qr_code`, `ean_upc`,
`databar`, `code_39`, `aztec`, `pdf417`, `telepen`.

## `symbologies/index.yml` schema

```yaml
- file: symbologies/qr_code.pgm   # relative to test/fixtures
  format: qr_code                 # most specific format we expect zxing to report (lead verifies)
  symbology: qr_code              # family
  text: "Hello"                   # expected Barcode#text with text_mode: :plain
  bytes_hex: "48656c6c6f"         # optional; expected raw bytes (required for binary payloads)
  content_type: text              # optional: text | binary | mixed | gs1 | iso15434 | unknown_eci
  encoder: "rqrcode"              # or e.g. "zint -b 58 --vers=2"
  read_options: {}                # optional ZXingFFI.read options needed (e.g. {ean_add_on: read})
  sequence: {index: 0, size: 2}   # optional structured-append expectation
  notes: ""
```

## Corpus manifest schema (`manifest.d/*.yml` → `manifest.yml`)

```yaml
- file: images/qr_rot90.png       # relative to test/fixtures
  category: rotation              # clean | rotation | exif | alpha | bit_depth | color | palette | multipage | fax |
                                  # inverted | tiny | multi | pdf_vector | pdf_embedded | pdf_scanned | pdf_rotated |
                                  # degraded | encrypted | false_positive | limits (| real: local corpus only)
  kind: png                       # expected sniffed type: pdf png jpeg tiff gif bmp webp heif avif pnm
  requires: []                    # optional extra capabilities: heif, avif, vips, image_magick, poppler, or
                                  # transformer (vips or ImageMagick, for the rotated_45 / raster high_res passes)
  effort: fast                    # lowest effort (fast | normal | thorough) at which every expected code is found
  options: {}                     # optional extra scan options, e.g. {password: "secret", pages: [1]}
  expect_error: null              # optional error class name raised by scan without options, e.g. PasswordRequired
  expected:                       # [] = no barcodes (false-positive fixture)
    - format: qr_code
      text: "https://example.com/1"
      bytes_hex: null             # optional
      page: 1
      center: [310.5, 402.0]      # optional: pixels of the displayed image (rasters) or PDF points from the top-left
                                  # of the displayed page (PDFs, i.e. Barcode#page_position)
      tolerance: 5                # optional, same unit as center
      rotation: 90                # optional, degrees clockwise 0..359
  notes: ""
```
