#!/usr/bin/env ruby
# frozen_string_literal: true

# PDF corpus generator (dev only; outputs are committed).
#
#   mise exec -- bundle exec ruby script/fixtures/pdfs.rb
#   mise exec -- bundle exec script/generate_fixtures pdfs
#
# Writes test/fixtures/pdfs/*.pdf (only synthetic content, no personal data) and the manifest fragment
# test/fixtures/manifest.d/pdfs.yml (schema: test/fixtures/README.md); rebuild the merged manifest afterwards with
# `script/generate_fixtures --manifest` (the driver does that automatically).
#
# Encoders are independent of zxing-cpp: rqrcode for QR (drawn module by module as vector rectangles, or rasterized
# to PNG) and zint for everything else (SVG through prawn-svg, or PNG). Pages are laid out with Prawn. Scans are
# simulated by rendering a vector page with pdftoppm, degrading it with ImageMagick (skew, blur, noise, JPEG or 1-bit
# threshold) and wrapping it again: Prawn for JPEG, tiff2pdf for CCITT G4, jbig2enc plus a minimal PDF writer for
# JBIG2. qpdf applies /Rotate and encryption and gives every post-processed file a deterministic /ID.
#
# Expectations are computed from the construction geometry, never by decoding: `center` is in PDF points from the
# top-left corner of the displayed page (after CropBox and /Rotate, i.e. Barcode#page_position), `rotation` is in
# degrees clockwise as displayed (omitted where a reader cannot report it exactly). `effort` lives in EFFORT below.
# Output is byte-for-byte reproducible, except that AES-256 encryption is randomized by qpdf; existing encrypted files
# are kept when their decrypted content and encryption parameters are unchanged (see #encrypt).
#
# Needs: zint, pdftoppm, magick, qpdf, tiff2pdf, tiffset, jbig2 (jbig2enc) and the Gemfile `fixtures` group.

require "bundler/setup"
require "fileutils"
require "json"
require "open3"
require "tmpdir"
require "yaml"
require "chunky_png"
require "prawn"
require "prawn-svg"
require "rqrcode"

module PdfFixtures
  ROOT = File.expand_path("../..", __dir__)
  OUT_DIR = File.join(ROOT, "test", "fixtures", "pdfs")
  MANIFEST = File.join(ROOT, "test", "fixtures", "manifest.d", "pdfs.yml")

  LETTER = [612.0, 792.0].freeze
  LETTER_LANDSCAPE = [792.0, 612.0].freeze
  A4 = [595.28, 841.89].freeze
  CREATED_AT = Time.utc(2026, 1, 1)
  TIFF_DATETIME = "2026:01:01 00:00:00"
  ZINT_UNITS_PER_MODULE = 2.0 # zint's SVG output draws one module (X-dimension) as 2 units at the default scale
  PASSWORD = "secret"
  OWNER_PASSWORD = "owner"
  UNICODE_PASSWORD = "pässwörd-ü"

  # Lowest effort (fast | normal | thorough) at which ZXingFFI.scan(stop: :exhaustive) finds every code, calibrated
  # with the Poppler loader (2026-09). No-barcode pages are declared thorough so every pass is checked for phantoms.
  EFFORT = {
    "vector_qr_code128_datamatrix.pdf" => "fast",
    "embedded_png_codes.pdf" => "fast",
    "embedded_low_res_upscaled.pdf" => "fast",
    "multipage_codes_p1_p3.pdf" => "fast",
    "cropbox_offset.pdf" => "fast",
    "rotate90_page.pdf" => "fast",
    "rotate180_page.pdf" => "fast",
    "rotate270_page.pdf" => "fast",
    "rotate_mixed_pages.pdf" => "fast",
    "rotation_right_angles_1d.pdf" => "fast",
    "rotation_right_angles_2d.pdf" => "fast",
    "rotation_30deg_code128.pdf" => "thorough",
    "rotation_45deg_code128.pdf" => "thorough",
    "rotation_30deg_qr_datamatrix.pdf" => "fast",
    "rotation_45deg_qr_datamatrix.pdf" => "fast",
    "tiny_qr_0_35in.pdf" => "fast",
    "tiny_datamatrix_0_2in.pdf" => "fast",
    "tiny_code128_0_65in.pdf" => "normal",
    "multi_mixed_symbologies.pdf" => "fast",
    "multi_identical_labels.pdf" => "fast",
    "scanned_jpeg_200dpi.pdf" => "fast",
    "scanned_ccitt_g4_300dpi.pdf" => "fast",
    "scanned_ccitt_g4_fax_204x98.pdf" => "fast",
    "scanned_jbig2_300dpi.pdf" => "fast",
    "encrypted_aes256_user_password.pdf" => "fast",
    "encrypted_aes256_user_password_supplied.pdf" => "fast",
    "encrypted_aes256_wrong_password.pdf" => "fast",
    "encrypted_aes256_owner_password_only.pdf" => "fast",
    "encrypted_rc4_128_user_password_supplied.pdf" => "fast",
    "encrypted_aes256_unicode_password.pdf" => "fast",
    "no_codes_dense_text.pdf" => "thorough",
    "no_codes_tables_numbers.pdf" => "thorough",
    "no_codes_vertical_bars.pdf" => "thorough",
    "no_codes_scanned_text.pdf" => "thorough",
    "huge_page_14400pt.pdf" => "fast",
    "huge_banner_14400x1000pt.pdf" => "fast",
    "huge_page_1000000pt.pdf" => "fast",
    "userunit_10.pdf" => "fast"
  }.freeze

  WORDS = %w[
    lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor incididunt ut labore et dolore magna
    aliqua enim ad minim veniam quis nostrud exercitation ullamco laboris nisi aliquip ex ea commodo consequat duis aute
    irure in reprehenderit voluptate velit esse cillum eu fugiat nulla pariatur excepteur sint occaecat cupidatat non
    proident sunt culpa qui officia deserunt mollit anim id est laborum
  ].freeze

  class CommandError < StandardError; end

  # Runs a command given as an argument vector (never through a shell) and returns its stdout.
  def self.run(*argv, ok: [0], chdir: nil)
    opts = {binmode: true}
    opts[:chdir] = chdir if chdir
    out, err, status = Open3.capture3(*argv.map(&:to_s), **opts)
    return out if ok.include?(status.exitstatus)

    raise CommandError, "#{argv.join(" ")} exited #{status.exitstatus}: #{err.strip}"
  end

  # qpdf exits 3 when it succeeded with warnings.
  def self.qpdf(*args) = run("qpdf", *args, ok: [0, 3])

  # Embedded fonts make text render identically on every machine (Poppler substitutes the base-14 fonts with
  # whatever fontconfig finds). Lato and Source Code Pro (SIL OFL) ship with the rdoc gem's darkfish template.
  module Fonts
    DIR_GLOB = File.join("gems", "rdoc-*", "lib", "rdoc", "generator", "template", "darkfish", "fonts")

    def self.dir
      @dir ||= begin
        roots = [Gem.default_dir, *Gem.path].uniq
        dirs = roots.flat_map { |root| Dir[File.join(root, DIR_GLOB)] }
        dirs << File.join(RbConfig::CONFIG["rubylibdir"], "rdoc", "generator", "template", "darkfish", "fonts")
        dirs.select { |d| File.file?(File.join(d, "Lato-Regular.ttf")) }.max || false
      end
    end

    def self.register(pdf)
      if dir
        pdf.font_families.update(
          "Sans" => {normal: File.join(dir, "Lato-Regular.ttf")},
          "Mono" => {normal: File.join(dir, "SourceCodePro-Regular.ttf")}
        )
      else
        warn "pdfs.rb: Lato/Source Code Pro not found (rdoc gem); falling back to non-embedded base-14 fonts"
        Prawn::Fonts::AFM.hide_m17n_warning = true
      end
    end

    def self.name(kind)
      mono = kind == :mono
      if dir
        mono ? "Mono" : "Sans"
      else
        mono ? "Courier" : "Helvetica"
      end
    end
  end

  # zint symbol rendered as SVG, with the bounding box of its dark modules (zint units).
  ZintSvg = Data.define(:data, :width, :bbox)

  module Zint
    def self.svg(symbology, text, height: nil, options: [])
      argv = ["zint", "--barcode=#{symbology}", "--filetype=svg", "--direct", "--notext", *options]
      argv << "--height=#{height}" if height
      argv << "--data=#{text}"
      data = PdfFixtures.run(*argv).force_encoding(Encoding::UTF_8)
      width = data[/<svg[^>]* width="([\d.]+)"/, 1].to_f
      ZintSvg.new(data: data, width: width, bbox: path_bbox(data))
    end

    # zint writes every dark module run as "M<x> <y>h<w>v<h>h-<w>Z".
    def self.path_bbox(svg)
      boxes = svg.scan(/M([\d.]+) ([\d.]+)h([\d.]+)v([\d.]+)h-[\d.]+Z/).map { |v| v.map(&:to_f) }
      raise "no modules found in zint SVG" if boxes.empty?

      [boxes.map { |x, _, _, _| x }.min, boxes.map { |_, y, _, _| y }.min,
        boxes.map { |x, _, w, _| x + w }.max, boxes.map { |_, y, _, h| y + h }.max]
    end

    # PNG with `px` pixels per module (zint rasters use 2 px per module per unit of --scale).
    def self.png(symbology, text, path, px:, height: nil, options: [])
      argv = ["zint", "--barcode=#{symbology}", "--filetype=png", "--notext", "--scale=#{px / 2.0}", *options]
      argv << "--height=#{height}" if height
      argv += ["--output=#{path}", "--data=#{text}"]
      PdfFixtures.run(*argv)
      path
    end
  end

  # QR code rendered by rqrcode, as a module matrix or a PNG.
  module Qr
    def self.modules(text, level: :m) = RQRCode::QRCode.new(text, level: level).modules

    def self.png(text, path, px:, border: 4, level: :m)
      mods = modules(text, level: level)
      side = (mods.size + 2 * border) * px
      img = ChunkyPNG::Image.new(side, side, ChunkyPNG::Color::WHITE)
      mods.each_with_index do |row, r|
        row.each_with_index do |dark, c|
          next unless dark

          x0 = (c + border) * px
          y0 = (r + border) * px
          img.rect(x0, y0, x0 + px - 1, y0 + px - 1, ChunkyPNG::Color::BLACK, ChunkyPNG::Color::BLACK)
        end
      end
      img.save(path, color_mode: ChunkyPNG::COLOR_GRAYSCALE, bit_depth: 8)
      [path, mods.size]
    end
  end

  # A Prawn document laid out in top-left page coordinates (x right, y down, points) that records every barcode it
  # draws. Prawn itself uses a bottom-left origin; #pt converts.
  class Sheet
    Code = Data.define(:format, :text, :page, :center, :size, :rotation)

    attr_reader :pdf, :codes, :page_sizes

    def initialize(title, page_size: LETTER)
      info = {Title: title, Creator: "zxing_ffi script/fixtures/pdfs.rb", Producer: "Prawn #{Prawn::VERSION}",
              CreationDate: CREATED_AT}
      @pdf = Prawn::Document.new(page_size: page_size.dup, margin: 0, info: info, compress: true)
      @page_sizes = [page_size]
      @codes = []
      Fonts.register(@pdf)
      @pdf.fill_color "000000"
      @pdf.stroke_color "000000"
    end

    def page = @page_sizes.size
    def width = @page_sizes.last[0]
    def height = @page_sizes.last[1]

    def start_new_page(size = @page_sizes.last)
      @pdf.start_new_page(size: size.dup, margin: 0)
      @page_sizes << size
    end

    def pt(x, y) = [x, height - y]

    def text(string, at:, width: 504, size: 9, font: :sans, leading: 1, box_height: nil, align: :left)
      @pdf.font(Fonts.name(font)) do
        @pdf.text_box(string, at: pt(*at), width: width, height: box_height || (height - at[1]), size: size,
          leading: leading, align: align, overflow: :truncate)
      end
    end

    def caption(string) = text(string, at: [36, 24], size: 8)

    def paragraphs(rng, at:, width:, height:, size: 8, count: 4)
      body = Array.new(count) { PdfFixtures.paragraph(rng) }.join("\n\n")
      text(body, at: at, width: width, box_height: height, size: size, align: :justify)
    end

    def line(from, to, width: 0.5)
      @pdf.line_width = width
      @pdf.stroke_line(pt(*from), pt(*to))
    end

    def rect(at, w, h, gray: nil, stroke: false)
      if gray
        @pdf.fill_color gray
        @pdf.fill_rectangle(pt(*at), w, h)
        @pdf.fill_color "000000"
      end
      @pdf.stroke_rectangle(pt(*at), w, h) if stroke
    end

    # QR code from rqrcode, one filled path of module runs (a single fill avoids anti-aliasing seams).
    def qr(text, center:, module_size:, rotate: 0, level: :m)
      mods = Qr.modules(text, level: level)
      side = mods.size * module_size
      rotated(center, rotate) do |ox, oy|
        left = ox - side / 2.0
        top = oy + side / 2.0
        mods.each_with_index do |row, r|
          runs(row) { |c, len| @pdf.rectangle([left + c * module_size, top - r * module_size], len * module_size, module_size) }
        end
        @pdf.fill
      end
      record("qr_code", text, center, [side, side], rotate)
    end

    # Any zint symbology as vector paths through prawn-svg; `module_size` is the X-dimension in points.
    def zint(format, symbology, text, center:, module_size:, rotate: 0, height: nil, options: [])
      svg = Zint.svg(symbology, text, height: height, options: options)
      k = module_size / ZINT_UNITS_PER_MODULE
      x0, y0, x1, y1 = svg.bbox
      mid_x = (x0 + x1) / 2.0 * k
      mid_y = (y0 + y1) / 2.0 * k
      rotated(center, rotate) do |ox, oy|
        @pdf.svg(svg.data, at: [ox - mid_x, oy + mid_y], width: svg.width * k, enable_web_requests: false)
      end
      record(format, text, center, [(x1 - x0) * k, (y1 - y0) * k], rotate)
    end

    # Raster image (PNG/JPEG) centered at `center`, drawn `size` points large; `symbol` is the barcode's own size.
    def image(path, format, text, center:, size:, symbol: size, rotate: 0)
      w, h = size
      rotated(center, rotate) { |ox, oy| @pdf.image(path, at: [ox - w / 2.0, oy + h / 2.0], width: w, height: h) }
      record(format, text, center, symbol, rotate)
    end

    def set_page_entry(key, value) = @pdf.page.dictionary.data[key] = value

    def render(path) = @pdf.render_file(path)

    private

    # Draws the block rotated clockwise (as displayed) by `degrees` about `center`; yields the center in Prawn space.
    def rotated(center, degrees)
      ox, oy = pt(*center)
      if (degrees % 360).zero?
        yield ox, oy
      else
        @pdf.rotate(-degrees, origin: [ox, oy]) { yield ox, oy }
      end
    end

    def runs(row)
      c = 0
      while c < row.size
        if row[c]
          start = c
          c += 1 while c < row.size && row[c]
          yield start, c - start
        else
          c += 1
        end
      end
    end

    def record(format, text, center, size, rotate)
      code = Code.new(format: format, text: text, page: page, center: center, size: size, rotation: rotate % 360)
      @codes << code
      code
    end
  end

  def self.sentence(rng)
    words = Array.new(rng.rand(6..14)) do
      case rng.rand(10)
      when 0 then format("%d,%03d.%02d", rng.rand(1..999), rng.rand(1000), rng.rand(100))
      when 1 then format("%04d-%02d-%02d", rng.rand(2010..2026), rng.rand(1..12), rng.rand(1..28))
      else WORDS.sample(random: rng)
      end
    end
    words.join(" ").capitalize + "."
  end

  def self.paragraph(rng) = Array.new(rng.rand(3..6)) { sentence(rng) }.join(" ")

  # Point transforms from the top-left coordinates of the unrotated page (w x h) to the displayed page.
  def self.rotate_point((x, y), (w, h), rotate)
    case rotate % 360
    when 0 then [x, y]
    when 90 then [h - y, x]
    when 180 then [w - x, h - y]
    when 270 then [y, w - x]
    else raise ArgumentError, "rotate must be a multiple of 90"
    end
  end

  # Rotation by `degrees` clockwise (as displayed) about the page center, as ImageMagick's `-distort SRT` does.
  def self.skew_point((x, y), (w, h), degrees)
    t = degrees * Math::PI / 180
    cx = w / 2.0
    cy = h / 2.0
    dx = x - cx
    dy = y - cy
    [cx + dx * Math.cos(t) - dy * Math.sin(t), cy + dx * Math.sin(t) + dy * Math.cos(t)]
  end

  # Builds every fixture into `stage` (a scratch directory) and returns the manifest entries.
  class Corpus
    def initialize(tmp, stage)
      @tmp = tmp
      @stage = stage
      @entries = []
      @counter = 0
    end

    def build
      vector
      embedded
      multipage
      cropbox
      page_rotation
      code_rotation
      tiny
      multi
      scanned
      encrypted
      false_positives
      limits
      @entries.sort_by { |e| e["file"] }
    end

    private

    # --- helpers ---------------------------------------------------------------------------------------------------

    def out(name) = File.join(@stage, name)

    def tmp(name)
      @counter += 1
      File.join(@tmp, "#{@counter}_#{name}")
    end

    # Tolerance (points, per axis): 15 % of the symbol's longer side, at least 6 pt. rotation: nil omits the key.
    def expected(code, center: code.center, rotation: code.rotation, extra_tolerance: 0)
      tolerance = [6.0, 0.15 * code.size.max].max + extra_tolerance
      hash = {"format" => code.format, "text" => code.text, "page" => code.page,
              "center" => center.map { |v| v.round(1) }, "tolerance" => tolerance.round(1)}
      hash["rotation"] = rotation unless rotation.nil?
      hash
    end

    def entry(file, category:, expected:, notes:, options: {}, expect_error: nil, requires: [])
      effort = EFFORT.fetch(file) { raise "no EFFORT for #{file}" }
      @entries << {"file" => "pdfs/#{file}", "category" => category, "kind" => "pdf", "requires" => requires,
                   "effort" => effort, "options" => options, "expect_error" => expect_error,
                   "expected" => expected, "notes" => notes}
    end

    def rng(seed) = Random.new(seed)

    # A plausible document body around the codes so pages are not empty.
    def filler(sheet, seed, top:, bottom: sheet.height - 54, size: 8)
      sheet.paragraphs(rng(seed), at: [54, top], width: sheet.width - 108, height: bottom - top, size: size, count: 6)
    end

    # --- vector ----------------------------------------------------------------------------------------------------

    def vector
      name = "vector_qr_code128_datamatrix.pdf"
      s = Sheet.new("Vector QR, Code 128 and Data Matrix")
      s.caption("Vector barcodes: QR = rqrcode modules as filled rectangles; Code 128 and Data Matrix = zint SVG via prawn-svg.")
      s.qr("https://example.com/zxf/vector/qr", center: [160, 190], module_size: 3)
      s.zint("code_128", "code128", "ZXF-VECTOR-128", center: [430, 190], module_size: 1.5, height: 40)
      s.zint("data_matrix", "datamatrix", "ZXF vector Data Matrix", center: [160, 380], module_size: 3, options: ["--square"])
      s.text("Order ZXF-2026-0001 / vector page", at: [330, 360], size: 11)
      filler(s, 1, top: 470)
      s.render(out(name))
      entry(name, category: "pdf_vector", expected: s.codes.map { |c| expected(c) },
        notes: "Born-digital page: QR drawn as rectangles (rqrcode), Code 128 and Data Matrix as zint SVG paths.")
    end

    # --- embedded images -------------------------------------------------------------------------------------------

    def embedded
      name = "embedded_png_codes.pdf"
      s = Sheet.new("Embedded barcode images")
      s.caption("Embedded images: QR PNG (rqrcode), Code 128 PNG (zint), Data Matrix PNG with transparent background, PDF417 JPEG.")
      qr_png, n = Qr.png("https://example.com/zxf/embedded/qr", tmp("qr.png"), px: 6)
      side = 3.0 * (n + 8)
      s.image(qr_png, "qr_code", "https://example.com/zxf/embedded/qr", center: [160, 190], size: [side, side],
        symbol: [3.0 * n, 3.0 * n])
      c128 = Zint.png("code128", "ZXF-EMBEDDED-128", tmp("c128.png"), px: 4, height: 40)
      w, h = png_size(c128)
      s.image(c128, "code_128", "ZXF-EMBEDDED-128", center: [430, 190], size: [w * 1.5 / 4, h * 1.5 / 4])
      dm = Zint.png("datamatrix", "ZXF embedded DM alpha", tmp("dm.png"), px: 8, options: ["--square", "--nobackground"])
      w, h = png_size(dm)
      s.image(dm, "data_matrix", "ZXF embedded DM alpha", center: [160, 380], size: [w * 3.0 / 8, h * 3.0 / 8])
      pdf417_png = Zint.png("pdf417", "ZXF embedded PDF417 JPEG", tmp("pdf417.png"), px: 4)
      pdf417 = tmp("pdf417.jpg")
      PdfFixtures.run("magick", pdf417_png, "-strip", "-colorspace", "Gray", "-quality", "85", pdf417)
      w, h = png_size(pdf417_png)
      s.image(pdf417, "pdf417", "ZXF embedded PDF417 JPEG", center: [430, 380], size: [w * 1.5 / 4, h * 1.5 / 4])
      filler(s, 2, top: 470)
      s.render(out(name))
      entry(name, category: "pdf_embedded", expected: s.codes.map { |c| expected(c) },
        notes: "Four image XObjects (Flate PNG, Flate PNG with SMask alpha, DCT JPEG); none covers the page, so " \
               "dpi: :auto should use the default DPI.")

      name = "embedded_low_res_upscaled.pdf"
      s = Sheet.new("Low-resolution barcode images scaled up")
      s.caption("Low-resolution images drawn large: QR at 1 px per module (plus 4-module border), Code 128 at 1 px per module.")
      qr_png, n = Qr.png("ZXF low-res QR", tmp("qr1.png"), px: 1)
      side = 4.0 * (n + 8)
      s.image(qr_png, "qr_code", "ZXF low-res QR", center: [180, 220], size: [side, side], symbol: [4.0 * n, 4.0 * n])
      c128 = Zint.png("code128", "ZXF-LOWRES-128", tmp("c128_1.png"), px: 1, height: 40)
      w, h = png_size(c128)
      s.image(c128, "code_128", "ZXF-LOWRES-128", center: [390, 470], size: [w * 1.6, h * 1.6])
      filler(s, 3, top: 560)
      s.render(out(name))
      entry(name, category: "pdf_embedded", expected: s.codes.map { |c| expected(c) },
        notes: "pdfimages reports a 29x29 px QR at 18 ppi and a 189x40 px Code 128 at 45 ppi; Poppler upscales them " \
               "(no /Interpolate). Must not be treated as a scanned page for dpi: :auto.")
    end

    def png_size(path)
      header = File.binread(path, 24)
      header[16, 8].unpack("NN")
    end

    # --- multi-page ------------------------------------------------------------------------------------------------

    def multipage
      name = "multipage_codes_p1_p3.pdf"
      s = Sheet.new("Three pages, codes on 1 and 3")
      s.caption("Page 1 of 3: QR + Code 128.")
      s.qr("ZXF page 1 QR", center: [150, 160], module_size: 3)
      s.zint("code_128", "code128", "ZXF-P1-128", center: [420, 160], module_size: 1.5, height: 40)
      filler(s, 10, top: 260)
      s.start_new_page
      s.caption("Page 2 of 3: text only, no barcodes.")
      filler(s, 11, top: 60)
      s.start_new_page
      s.caption("Page 3 of 3: Data Matrix + Code 128.")
      s.zint("data_matrix", "datamatrix", "ZXF page 3 Data Matrix", center: [150, 600], module_size: 3, options: ["--square"])
      s.zint("code_128", "code128", "ZXF-P3-128", center: [420, 600], module_size: 1.5, height: 40)
      filler(s, 12, top: 60, bottom: 520)
      s.render(out(name))
      entry(name, category: "multipage", expected: s.codes.map { |c| expected(c) },
        notes: "For pages: selection tests: pages: [2] => []; pages: [3] => the two page-3 codes; page 1 codes are " \
               "at the top, page 3 codes at the bottom.")
    end

    # --- CropBox ---------------------------------------------------------------------------------------------------

    def cropbox
      name = "cropbox_offset.pdf"
      crop = [40.0, 50.0, 572.0, 752.0] # llx lly urx ury (PDF user space)
      s = Sheet.new("CropBox smaller than MediaBox")
      2.times do |i|
        s.start_new_page if i == 1
        s.caption("Outside the CropBox: this line and the QR next to it are cropped away.")
        s.qr("ZXF hidden outside CropBox #{i + 1}", center: [560, 22], module_size: 1.2)
        s.text("CropBox [40 50 572 752] of MediaBox [0 0 612 792]#{", page /Rotate 90" if i == 1}", at: [60, 60], size: 9)
        s.qr("ZXF CropBox page #{i + 1} QR", center: [170, 200], module_size: 3)
        s.zint("code_128", "code128", "ZXF-CROP-P#{i + 1}", center: [420, 520], module_size: 1.5, height: 40)
        s.set_page_entry(:CropBox, crop)
      end
      raw = tmp("cropbox.pdf")
      s.render(raw)
      PdfFixtures.qpdf("--deterministic-id", raw, "--rotate=+90:2", out(name))
      crop_w = crop[2] - crop[0]
      crop_h = crop[3] - crop[1]
      visible = s.codes.reject { |c| c.text.include?("hidden") }
      list = visible.map do |c|
        # Top-left MediaBox coordinates -> top-left CropBox coordinates -> displayed (rotated) coordinates.
        local = [c.center[0] - crop[0], c.center[1] - (LETTER[1] - crop[3])]
        rot = (c.page == 2) ? 90 : 0
        expected(c, center: PdfFixtures.rotate_point(local, [crop_w, crop_h], rot), rotation: (c.rotation + rot) % 360)
      end
      entry(name, category: "pdf_vector", expected: list,
        notes: "CropBox [40 50 572 752] inside a letter MediaBox; page 2 also has /Rotate 90. pdfinfo reports the " \
               "CropBox size (532 x 702 pts) but pdftoppm renders the MediaBox unless -cropbox is passed. A QR in " \
               "the cropped-away margin must NOT be reported; centers are relative to the displayed CropBox.")
    end

    # --- /Rotate ---------------------------------------------------------------------------------------------------

    def page_rotation
      [90, 180, 270].each do |rot|
        name = "rotate#{rot}_page.pdf"
        s = Sheet.new("Page with /Rotate #{rot}")
        s.caption("This page carries /Rotate #{rot}; content is drawn upright in user space. TOP of user space here.")
        s.qr("ZXF /Rotate #{rot} QR", center: [150, 170], module_size: 3)
        s.zint("code_128", "code128", "ZXF-ROTATE-#{rot}", center: [400, 460], module_size: 1.5, height: 40)
        filler(s, 20 + rot, top: 540)
        raw = tmp("rot#{rot}.pdf")
        s.render(raw)
        PdfFixtures.qpdf("--deterministic-id", raw, "--rotate=+#{rot}:1", out(name))
        list = s.codes.map do |c|
          expected(c, center: PdfFixtures.rotate_point(c.center, LETTER, rot), rotation: (c.rotation + rot) % 360)
        end
        displayed = (rot == 180) ? "612 x 792" : "792 x 612"
        entry(name, category: "pdf_rotated", expected: list,
          notes: "Letter page with /Rotate #{rot} (qpdf --rotate). pdfinfo reports the unrotated 612 x 792 size and " \
                 "rot #{rot}; the displayed page is #{displayed} pts and the codes appear rotated #{rot} degrees clockwise.")
      end

      name = "rotate_mixed_pages.pdf"
      sizes = [LETTER, LETTER, A4, LETTER_LANDSCAPE]
      rotations = [0, 90, 180, 270]
      s = Sheet.new("Four pages: /Rotate 0, 90, 180, 270 and different sizes")
      sizes.each_with_index do |size, i|
        s.start_new_page(size) if i.positive?
        s.caption("Page #{i + 1}: #{size.map { |v| v.round(2) }.join(" x ")} pts, /Rotate #{rotations[i]}.")
        s.qr("ZXF mixed page #{i + 1} QR", center: [140, 150], module_size: 3)
        s.zint("code_128", "code128", "ZXF-MIXED-P#{i + 1}", center: [size[0] - 170, size[1] - 150], module_size: 1.5,
          height: 40)
      end
      raw = tmp("mixed.pdf")
      s.render(raw)
      PdfFixtures.qpdf("--deterministic-id", raw, "--rotate=+90:2", "--rotate=+180:3", "--rotate=+270:4", out(name))
      list = s.codes.map do |c|
        rot = rotations[c.page - 1]
        expected(c, center: PdfFixtures.rotate_point(c.center, sizes[c.page - 1], rot), rotation: (c.rotation + rot) % 360)
      end
      entry(name, category: "pdf_rotated", expected: list,
        notes: "Per-page geometry: p1 letter /Rotate 0, p2 letter /Rotate 90, p3 A4 /Rotate 180, p4 landscape " \
               "letter (792 x 612) /Rotate 270 (displayed 612 x 792). Exercises pdfinfo -f/-l per-page size and rot.")
    end

    # --- codes drawn at an angle -----------------------------------------------------------------------------------

    def code_rotation
      name = "rotation_right_angles_1d.pdf"
      s = Sheet.new("Code 128 at 0, 90, 180, 270 degrees")
      s.caption("Code 128 rotated 0/90/180/270 degrees clockwise (Prawn rotate).")
      {0 => [200, 150], 180 => [200, 330], 90 => [470, 260], 270 => [470, 560]}.each do |deg, center|
        s.zint("code_128", "code128", format("ZXF-ROT-%03d", deg), center: center, module_size: 1.5, height: 30, rotate: deg)
      end
      s.render(out(name))
      entry(name, category: "rotation", expected: s.codes.map { |c| expected(c) },
        notes: "Four Code 128 symbols rotated clockwise by 0/90/180/270 degrees; try_rotate (library default) covers them.")

      name = "rotation_right_angles_2d.pdf"
      s = Sheet.new("QR and Data Matrix at 0, 90, 180, 270 degrees")
      s.caption("QR (left) and Data Matrix (right) rotated 0/90/180/270 degrees clockwise.")
      [0, 90, 180, 270].each_with_index do |deg, i|
        y = 130 + i * 170
        s.qr(format("ZXF QR rotated %03d", deg), center: [180, y], module_size: 3, rotate: deg)
        s.zint("data_matrix", "datamatrix", format("ZXF DM rotated %03d", deg), center: [430, y], module_size: 3,
          rotate: deg, options: ["--square"])
      end
      s.render(out(name))
      entry(name, category: "rotation", expected: s.codes.map { |c| expected(c) },
        notes: "2D symbols rotated clockwise by 0/90/180/270 degrees.")

      [30, 45].each do |deg|
        name = "rotation_#{deg}deg_code128.pdf"
        s = Sheet.new("Code 128 at #{deg} degrees")
        s.caption("Code 128 rotated #{deg} degrees clockwise (top) and #{deg} degrees counter-clockwise (bottom).")
        # Short, tall symbols (~100 x 50 modules): after the 45-degree pass a 30-degree code is 15 degrees off the
        # scan direction and a row still crosses every bar (tan 15 * 100 < 50); unrotated it cannot (tan 30 * 100 > 50).
        s.zint("code_128", "code128", "ZXF-#{deg}", center: [306, 250], module_size: 1.5, height: 50, rotate: deg)
        s.zint("code_128", "code128", "ZXF-#{360 - deg}", center: [306, 560], module_size: 1.5, height: 50,
          rotate: 360 - deg)
        s.render(out(name))
        if deg == 45
          list = s.codes.map { |c| expected(c) }
          detail = "45 maps onto the scan direction exactly"
        else
          # A linear reader reports its scan-line direction: the rotated_45 pass says 45/315 for these 30/330 codes.
          list = s.codes.map { |c| expected(c, rotation: nil) }
          detail = "30 leaves a 15-degree residual. rotation omitted: a linear reader reports its scan-line " \
                   "direction (45/315 from the rotated_45 pass), not the true 30/330"
        end
        entry(name, category: "rotation", expected: list, requires: ["transformer"],
          notes: "Code 128 at #{deg} and #{360 - deg} degrees: no row or column scan crosses every bar, so they " \
                 "need the rotated_45 pass (thorough, needs a transformer: vips or ImageMagick); #{detail}.")

        name = "rotation_#{deg}deg_qr_datamatrix.pdf"
        s = Sheet.new("QR and Data Matrix at #{deg} degrees")
        s.caption("QR (top) and Data Matrix (bottom) rotated #{deg} degrees clockwise.")
        s.qr("ZXF QR at #{deg} degrees", center: [306, 230], module_size: 3, rotate: deg)
        s.zint("data_matrix", "datamatrix", "ZXF DM at #{deg} degrees", center: [306, 540], module_size: 3, rotate: deg,
          options: ["--square"])
        s.render(out(name))
        entry(name, category: "rotation", expected: s.codes.map { |c| expected(c) },
          notes: "2D symbols at #{deg} degrees; the 2D detectors are rotation invariant, so the base pass should find them.")
      end
    end

    # --- tiny codes ------------------------------------------------------------------------------------------------

    def tiny
      name = "tiny_qr_0_35in.pdf"
      s = Sheet.new("0.35 inch QR on a letter page")
      s.caption("A 0.35 inch (25.2 pt) QR code near the bottom-right corner of a text page.")
      filler(s, 30, top: 60, bottom: 690)
      mods = Qr.modules("https://example.com/zxf/tiny").size
      s.qr("https://example.com/zxf/tiny", center: [548, 738], module_size: 25.2 / mods)
      s.render(out(name))
      entry(name, category: "tiny", expected: s.codes.map { |c| expected(c) },
        notes: "QR symbol side 0.35 in (#{mods} modules of #{(25.2 / mods).round(2)} pt = " \
               "#{(25.2 / mods / 72 * 300).round(1)} px at 300 dpi).")

      name = "tiny_datamatrix_0_2in.pdf"
      s = Sheet.new("0.2 inch Data Matrix on a letter page")
      s.caption("A 0.2 inch (14.4 pt) Data Matrix in the top-right margin of a text page.")
      svg = Zint.svg("datamatrix", "ZXF-TDM", options: ["--square"])
      dm_modules = (svg.bbox[2] - svg.bbox[0]) / ZINT_UNITS_PER_MODULE
      s.zint("data_matrix", "datamatrix", "ZXF-TDM", center: [560, 52], module_size: 14.4 / dm_modules, options: ["--square"])
      filler(s, 31, top: 80)
      s.render(out(name))
      entry(name, category: "tiny", expected: s.codes.map { |c| expected(c) },
        notes: "Data Matrix #{dm_modules.to_i}x#{dm_modules.to_i} modules, 0.2 in side " \
               "(#{(14.4 / dm_modules / 72 * 300).round(1)} px per module at 300 dpi).")

      name = "tiny_code128_0_65in.pdf"
      s = Sheet.new("0.65 inch Code 128 on a letter page")
      s.caption("A 0.65 inch wide Code 128 (0.25 in bar height) at the bottom-left of a text page.")
      filler(s, 32, top: 60, bottom: 690)
      svg = Zint.svg("code128", "ZXF-T128", height: 10)
      c128_modules = (svg.bbox[2] - svg.bbox[0]) / ZINT_UNITS_PER_MODULE
      x_dim = 0.65 * 72 / c128_modules
      s.zint("code_128", "code128", "ZXF-T128", center: [110, 735], module_size: x_dim, height: (18 / x_dim).round(1))
      s.render(out(name))
      entry(name, category: "tiny", expected: s.codes.map { |c| expected(c) },
        notes: "Code 128 of #{c128_modules.to_i} modules in 0.65 in: X-dimension #{x_dim.round(3)} pt " \
               "(#{(x_dim / 72 * 25.4).round(2)} mm) = " \
               "#{(x_dim / 72 * 300).round(2)} px at 300 dpi (needs the high_res pass).")
    end

    # --- several codes per page ------------------------------------------------------------------------------------

    def multi
      name = "multi_mixed_symbologies.pdf"
      s = Sheet.new("Seven symbologies on one page")
      s.caption("QR, Micro QR, Data Matrix, Aztec, PDF417 (vector, zint/rqrcode) and EAN-13, Code 128.")
      s.qr("https://example.com/zxf/multi/qr", center: [150, 130], module_size: 2.5)
      s.zint("micro_qr_code", "microqr", "ZXF-MQR1", center: [440, 130], module_size: 3)
      s.zint("data_matrix", "datamatrix", "ZXF multi Data Matrix", center: [150, 300], module_size: 2.5, options: ["--square"])
      s.zint("aztec", "aztec", "ZXF multi Aztec", center: [440, 300], module_size: 2.5)
      s.zint("pdf417", "pdf417", "ZXF multi PDF417 0123456789", center: [306, 460], module_size: 1.2)
      s.zint("ean_13", "ean13", "4006381333931", center: [170, 640], module_size: 1.5, height: 50,
        options: ["--guarddescent=0"])
      s.zint("code_128", "code128", "ZXF-MULTI-128", center: [440, 640], module_size: 1.3, height: 40)
      s.render(out(name))
      entry(name, category: "multi", expected: s.codes.map { |c| expected(c) },
        notes: "Seven different symbologies (all vector) on one letter page.")

      name = "multi_identical_labels.pdf"
      s = Sheet.new("Identical labels at different positions")
      s.caption("Two identical QR labels and two identical Code 128 labels at different positions.")
      s.qr("ZXF-LABEL-0001", center: [150, 150], module_size: 3)
      s.zint("code_128", "code128", "SKU-000123", center: [430, 160], module_size: 1.5, height: 40)
      s.zint("code_128", "code128", "SKU-000123", center: [180, 620], module_size: 1.5, height: 40)
      s.qr("ZXF-LABEL-0001", center: [460, 640], module_size: 3)
      filler(s, 40, top: 260, bottom: 540)
      s.render(out(name))
      entry(name, category: "multi", expected: s.codes.map { |c| expected(c) },
        notes: "Same content at different positions is not a duplicate: all four must be reported.")
    end

    # --- scans -----------------------------------------------------------------------------------------------------

    # A vector "document" page that gets rasterized and degraded.
    def scan_source(title, seed, codes: true)
      s = Sheet.new(title)
      s.text("ZXF SCANNED DOCUMENT", at: [54, 50], size: 16)
      s.text("Lorem ipsum #{seed}-2026 · dolor sit amet, consectetur adipiscing elit", at: [54, 74], size: 9)
      yield s if codes
      top = codes ? 350 : 110
      filler(s, seed, top: top, bottom: 560, size: 9)
      table(s, rng(seed + 1), top: 580, rows: 8)
      s
    end

    def table(sheet, rng, top:, rows:, left: 54, widths: [150, 90, 90, 84, 90])
      row_h = 16
      x = left
      xs = widths.map { |w| x.tap { x += w } } << x
      (rows + 2).times { |r| sheet.line([left, top + r * row_h], [x, top + r * row_h], width: 0.6) }
      xs.each { |cx| sheet.line([cx, top], [cx, top + (rows + 1) * row_h], width: 0.6) }
      headers = %w[Lorem Ipsum Dolor Sit Amet]
      headers.each_with_index { |h, i| sheet.text(h, at: [xs[i] + 3, top + 4], width: widths[i] - 6, size: 8) }
      rows.times do |r|
        y = top + (r + 1) * row_h + 4
        cells = [PdfFixtures::WORDS.sample(2, random: rng).join(" "),
          format("%04d-%02d-%02d", rng.rand(2020..2026), rng.rand(1..12), rng.rand(1..28)),
          format("REF%07d", rng.rand(10_000_000)), rng.rand(1..999).to_s,
          format("%d,%03d.%02d", rng.rand(1..99), rng.rand(1000), rng.rand(100))]
        cells.each_with_index do |v, i|
          sheet.text(v, at: [xs[i] + 3, y], width: widths[i] - 6, size: 8, font: (i >= 3) ? :mono : :sans,
            align: (i >= 3) ? :right : :left)
        end
      end
    end

    def scanned
      skew = 0.8
      src = scan_source("Scan source (JPEG)", 50) do |s|
        s.qr("https://example.com/zxf/scan/jpeg", center: [150, 180], module_size: 3)
        s.zint("data_matrix", "datamatrix", "ZXF scan JPEG DM", center: [460, 180], module_size: 3, options: ["--square"])
        s.zint("code_128", "code128", "ZXF-SCAN-JPEG", center: [306, 290], module_size: 1.5, height: 40)
      end
      pgm = rasterize(src, "jpeg_src", 200)
      jpg = tmp("scan.jpg")
      PdfFixtures.run("magick", pgm, "-strip", "-background", "white", "-virtual-pixel", "background", "-distort", "SRT",
        skew.to_s, "-blur", "0x0.7", "-seed", "4242", "-attenuate", "0.25", "+noise", "Gaussian", "+level", "7%,95%",
        "-colorspace", "Gray", "-type", "Grayscale", "-quality", "45", "-sampling-factor", "1x1", jpg)
      name = "scanned_jpeg_200dpi.pdf"
      page = Sheet.new("Scanned page (JPEG, 200 dpi)")
      page.pdf.image(jpg, at: [0, LETTER[1]], width: LETTER[0], height: LETTER[1])
      page.render(out(name))
      entry(name, category: "pdf_scanned", expected: skewed(src, skew),
        notes: "Full-page 1700x2200 grayscale JPEG (quality 45) at 200 ppi: skew #{skew} degrees clockwise, blur, " \
               "noise, gray paper. pdfimages: 1 image covering the page, 200 x 200 ppi (dpi: :auto => 200). " \
               "rotation omitted (skew).")

      skew = -0.5
      src = scan_source("Scan source (CCITT G4)", 60) do |s|
        s.qr("https://example.com/zxf/scan/g4", center: [150, 180], module_size: 3)
        s.zint("pdf417", "pdf417", "ZXF scan G4 PDF417", center: [440, 180], module_size: 1.2)
        s.zint("code_128", "code128", "ZXF-SCAN-G4", center: [306, 290], module_size: 1.5, height: 40)
      end
      pgm = rasterize(src, "g4_src", 300)
      name = "scanned_ccitt_g4_300dpi.pdf"
      g4_pdf(pgm, out(name), density: "300", ops: ["-distort", "SRT", skew.to_s, "-blur", "0x0.6", "-seed", "6060",
        "-attenuate", "0.05", "+noise", "Impulse", "-threshold", "50%"])
      entry(name, category: "pdf_scanned", expected: skewed(src, skew),
        notes: "1-bit 2550x3300 CCITT G4 image at 300 ppi via tiff2pdf: skew #{-skew} degrees counter-clockwise, " \
               "blur, speckles, threshold. pdfimages: enc ccitt, 300 x 300 ppi. rotation omitted (skew).")

      src = scan_source("Scan source (fax 204x98)", 70) do |s|
        s.qr("ZXF fax QR", center: [150, 200], module_size: 4.5)
        s.zint("code_128", "code128", "ZXF-FAX-128", center: [410, 200], module_size: 2, height: 40)
      end
      pgm = rasterize(src, "fax_src", nil, rx: 204, ry: 98)
      name = "scanned_ccitt_g4_fax_204x98.pdf"
      g4_pdf(pgm, out(name), density: "204x98", ops: ["-threshold", "60%"])
      entry(name, category: "pdf_scanned", expected: src.codes.map { |c| expected(c, extra_tolerance: 4) },
        notes: "Fax resolution: 1734x1078 CCITT G4 image, 204 x 98 ppi (non-square) stretched over a letter page. " \
               "pdfimages reports x-ppi 204, y-ppi 98; the renderer resamples to square pixels.")

      skew = 0.3
      src = scan_source("Scan source (JBIG2)", 80) do |s|
        s.qr("https://example.com/zxf/scan/jbig2", center: [150, 180], module_size: 3)
        s.zint("data_matrix", "datamatrix", "ZXF scan JBIG2 DM", center: [460, 180], module_size: 3, options: ["--square"])
        s.zint("code_128", "code128", "ZXF-SCAN-JBIG2", center: [306, 290], module_size: 1.5, height: 40)
      end
      pgm = rasterize(src, "jbig2_src", 300)
      name = "scanned_jbig2_300dpi.pdf"
      jbig2_pdf(pgm, out(name), ops: ["-distort", "SRT", skew.to_s, "-blur", "0x0.6", "-threshold", "55%"])
      entry(name, category: "pdf_scanned", expected: skewed(src, skew),
        notes: "1-bit 2550x3300 JBIG2 image (jbig2enc symbol mode -s -p, lossy, with JBIG2Globals) at 300 ppi: skew " \
               "#{skew} degrees clockwise. Poppler decodes JBIG2 natively. rotation omitted (skew).")
    end

    def rasterize(sheet, name, dpi, rx: nil, ry: nil)
      pdf = tmp("#{name}.pdf")
      sheet.render(pdf)
      base = tmp(name)
      res = dpi ? ["-r", dpi.to_s] : ["-rx", rx.to_s, "-ry", ry.to_s]
      PdfFixtures.run("pdftoppm", "-gray", *res, "-singlefile", pdf, base)
      "#{base}.pgm"
    end

    def skewed(src, skew)
      src.codes.map do |c|
        expected(c, center: PdfFixtures.skew_point(c.center, LETTER, skew), rotation: nil, extra_tolerance: 4)
      end
    end

    def g4_pdf(pgm, path, density:, ops:)
      tif = tmp("page.tif")
      PdfFixtures.run("magick", pgm, "-strip", "-background", "white", "-virtual-pixel", "background", *ops, "-type",
        "bilevel", "-define", "tiff:photometric=min-is-white", "-compress", "Group4", "-units", "PixelsPerInch",
        "-density", density, tif)
      PdfFixtures.run("tiffset", "-s", "306", TIFF_DATETIME, tif) # tiff2pdf uses DateTime for CreationDate/ModDate
      raw = tmp("g4.pdf")
      PdfFixtures.run("tiff2pdf", "-o", raw, tif)
      PdfFixtures.qpdf("--deterministic-id", raw, path)
    end

    # jbig2enc's PDF-ready output (-p) wrapped by a minimal PDF writer (jbig2topdf.py does the same in Python).
    def jbig2_pdf(pgm, path, ops:)
      dir = tmp("jbig2")
      FileUtils.mkdir_p(dir)
      png = File.join(dir, "page.png")
      # No -strip here: ImageMagick then omits the pHYs chunk and jbig2enc would see no resolution.
      PdfFixtures.run("magick", pgm, "-background", "white", "-virtual-pixel", "background", *ops, "-type", "bilevel",
        "-units", "PixelsPerInch", "-density", "300", png)
      PdfFixtures.run("jbig2", "-s", "-p", "-b", "page", "page.png", chdir: dir)
      globals = File.binread(File.join(dir, "page.sym"))
      data = File.binread(File.join(dir, "page.0000"))
      px_w, px_h, xres, yres = data[11, 16].unpack("N4")
      raise "jbig2 page has no resolution (#{xres}x#{yres})" unless xres.positive? && yres.positive?
      w = (px_w * 72.0 / xres).round(2)
      h = (px_h * 72.0 / yres).round(2)
      content = "q #{w} 0 0 #{h} 0 0 cm /Im1 Do Q"
      objects = [
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 #{w} #{h}] /Contents 4 0 R " \
        "/Resources << /ProcSet [/PDF /ImageB] /XObject << /Im1 5 0 R >> >> >>",
        stream("<< /Length #{content.bytesize} >>", content),
        stream("<< /Type /XObject /Subtype /Image /Width #{px_w} /Height #{px_h} /ColorSpace /DeviceGray " \
               "/BitsPerComponent 1 /Filter /JBIG2Decode /DecodeParms << /JBIG2Globals 6 0 R >> " \
               "/Length #{data.bytesize} >>", data),
        stream("<< /Length #{globals.bytesize} >>", globals),
        "<< /Producer (jbig2enc + zxing_ffi script/fixtures/pdfs.rb) /CreationDate (D:20260101000000Z) >>"
      ]
      raw = tmp("jbig2.pdf")
      File.binwrite(raw, write_pdf(objects, info: 7))
      PdfFixtures.qpdf("--deterministic-id", raw, path)
    end

    def stream(dict, data) = "#{dict}\nstream\n".b + data.b + "\nendstream".b

    def write_pdf(objects, info:)
      body = "%PDF-1.5\n%\xE2\xE3\xCF\xD3\n".b
      offsets = objects.each_with_index.map do |obj, i|
        offset = body.bytesize
        body << "#{i + 1} 0 obj\n".b << obj.b << "\nendobj\n".b
        offset
      end
      xref = body.bytesize
      body << "xref\n0 #{objects.size + 1}\n0000000000 65535 f \n".b
      offsets.each { |o| body << format("%010d 00000 n \n", o).b }
      body << "trailer\n<< /Size #{objects.size + 1} /Root 1 0 R /Info #{info} 0 R >>\nstartxref\n#{xref}\n%%EOF\n".b
    end

    # --- encryption ------------------------------------------------------------------------------------------------

    def encrypted
      s = Sheet.new("Encrypted fixture")
      s.caption("Encrypted PDF fixture (see manifest notes for the password).")
      s.qr("ZXF encrypted QR", center: [160, 180], module_size: 3)
      s.zint("code_128", "code128", "ZXF-ENCRYPTED-128", center: [420, 180], module_size: 1.5, height: 40)
      filler(s, 90, top: 280)
      plain = tmp("plain.pdf")
      s.render(plain)
      codes = s.codes.map { |c| expected(c) }

      aes = out("encrypted_aes256_user_password.pdf")
      encrypt(plain, aes, PASSWORD, "--user-password=#{PASSWORD}", "--owner-password=#{OWNER_PASSWORD}", "--bits=256")
      entry("encrypted_aes256_user_password.pdf", category: "encrypted", expected: [], expect_error: "PasswordRequired",
        notes: "AES-256 (R6) with user password \"#{PASSWORD}\" (owner \"#{OWNER_PASSWORD}\"). Scanning without a " \
               "password must raise PasswordRequired before rendering. Poppler prints \"Command Line Error: " \
               "Incorrect password\" (exit 1) both without and with a wrong password.")
      FileUtils.cp(aes, out("encrypted_aes256_user_password_supplied.pdf"))
      entry("encrypted_aes256_user_password_supplied.pdf", category: "encrypted", expected: codes,
        options: {"password" => PASSWORD},
        notes: "Byte-identical copy of encrypted_aes256_user_password.pdf; opens with options {password: \"#{PASSWORD}\"}.")
      FileUtils.cp(aes, out("encrypted_aes256_wrong_password.pdf"))
      entry("encrypted_aes256_wrong_password.pdf", category: "encrypted", expected: [],
        options: {"password" => "wrong"}, expect_error: "IncorrectPassword",
        notes: "Byte-identical copy of encrypted_aes256_user_password.pdf scanned with a wrong password: " \
               "IncorrectPassword (a PasswordRequired subclass).")

      name = "encrypted_aes256_owner_password_only.pdf"
      encrypt(plain, out(name), OWNER_PASSWORD, "--owner-password=#{OWNER_PASSWORD}", "--bits=256", "--print=none",
        "--extract=n", "--modify=none")
      entry(name, category: "encrypted", expected: codes,
        notes: "AES-256 with an empty user password and owner password \"#{OWNER_PASSWORD}\" (print/extract/modify " \
               "restricted). pdfinfo says \"Encrypted: yes\" but it opens without a password: must NOT raise " \
               "PasswordRequired.")

      name = "encrypted_rc4_128_user_password_supplied.pdf"
      encrypt(plain, out(name), PASSWORD, "--user-password=#{PASSWORD}", "--owner-password=#{OWNER_PASSWORD}",
        "--bits=128", "--use-aes=n", weak: true)
      entry(name, category: "encrypted", expected: codes, options: {"password" => PASSWORD},
        notes: "Legacy RC4 128-bit (R3) with user password \"#{PASSWORD}\"; opens with the password option.")

      name = "encrypted_aes256_unicode_password.pdf"
      encrypt(plain, out(name), UNICODE_PASSWORD, "--user-password=#{UNICODE_PASSWORD}",
        "--owner-password=#{OWNER_PASSWORD}", "--bits=256")
      entry(name, category: "encrypted", expected: codes, options: {"password" => UNICODE_PASSWORD},
        notes: "AES-256 with a non-ASCII user password (UTF-8 in argv, SASLprep in the PDF); Poppler accepts it via -upw.")
    end

    # qpdf's AES-256 output is randomized (salts, IVs), so the committed file is reused when it still decrypts to the
    # same content with the same encryption parameters; regenerating then produces no spurious binary diffs.
    def encrypt(plain, path, password, *args, weak: false)
      fresh = tmp("encrypted.pdf")
      extra = weak ? ["--allow-weak-crypto", "--static-id"] : ["--static-id"]
      PdfFixtures.qpdf(*extra, plain, "--encrypt", *args, "--", fresh)
      committed = File.join(OUT_DIR, File.basename(path))
      reuse = File.exist?(committed) && same_encrypted?(committed, fresh, password)
      FileUtils.cp(reuse ? committed : fresh, path)
    end

    def same_encrypted?(a, b, password)
      [a, b].map do |f|
        dec = tmp("decrypted.pdf")
        PdfFixtures.qpdf("--password=#{password}", "--decrypt", "--static-id", f, dec)
        info = PdfFixtures.qpdf("--password=#{password}", "--show-encryption", f)
        [File.binread(dec), info]
      end.uniq.size == 1
    rescue CommandError
      false
    end

    # --- pages without barcodes ------------------------------------------------------------------------------------

    def false_positives
      name = "no_codes_dense_text.pdf"
      s = Sheet.new("Dense small text, no barcodes")
      2.times do |p|
        s.start_new_page if p.positive?
        r = rng(100 + p)
        [36, 318].each do |x|
          body = Array.new(30) { PdfFixtures.paragraph(r) }.join("\n")
          s.text(body, at: [x, 36], width: 258, box_height: 720, size: 6, align: :justify)
        end
      end
      s.render(out(name))
      entry(name, category: "false_positive", expected: [],
        notes: "Two pages of 6 pt justified text in two columns (words, amounts, dates); no barcodes.")

      name = "no_codes_tables_numbers.pdf"
      s = Sheet.new("Tables and columns of numbers, no barcodes")
      r = rng(110)
      s.text("Lorem ipsum · dolor sit amet", at: [36, 30], size: 12)
      table(s, r, top: 60, rows: 20, left: 36, widths: [170, 80, 90, 70, 130])
      grid(s, r, top: 420, rows: 18, cols: 9)
      s.start_new_page
      s.text("Consectetur adipiscing elit", at: [36, 30], size: 12)
      [36, 222, 408].each do |x|
        col = Array.new(80) { format("%12s", format("%.2f", r.rand * 10**r.rand(1..6))) }.join("\n")
        s.text(col, at: [x, 60], width: 168, box_height: 700, size: 6.5, font: :mono, leading: 0)
        s.line([x + 172, 56], [x + 172, 760], width: 0.8)
      end
      s.render(out(name))
      entry(name, category: "false_positive", expected: [],
        notes: "Ruled tables, a dense 9-column numeric grid and three columns of right-aligned amounts; no barcodes.")

      name = "no_codes_vertical_bars.pdf"
      s = Sheet.new("Repeated vertical bars, no barcodes")
      vertical_bars(s, rng(120))
      s.render(out(name))
      entry(name, category: "false_positive", expected: [],
        notes: "Ruler ticks, thin-bar histogram, vertical hatching, zebra columns and '|||' text lines: the usual " \
               "sources of phantom ITF/Codabar/DataBar reads. No barcodes.")

      name = "no_codes_scanned_text.pdf"
      src = scan_source("Scan source (no codes)", 130, codes: false)
      pgm = rasterize(src, "fp_src", 200)
      jpg = tmp("fp.jpg")
      PdfFixtures.run("magick", pgm, "-strip", "-background", "white", "-virtual-pixel", "background", "-distort", "SRT",
        "-1.2", "-blur", "0x0.8", "-seed", "1313", "-attenuate", "0.3", "+noise", "Gaussian", "+level", "8%,94%",
        "-colorspace", "Gray", "-type", "Grayscale", "-quality", "40", "-sampling-factor", "1x1", jpg)
      s = Sheet.new("Scanned page without barcodes")
      s.pdf.image(jpg, at: [0, LETTER[1]], width: LETTER[0], height: LETTER[1])
      s.render(out(name))
      entry(name, category: "false_positive", expected: [],
        notes: "Degraded 200 ppi JPEG scan of a text + table page (skew, blur, noise); no barcodes.")
    end

    def grid(sheet, rng, top:, rows:, cols:, left: 36, width: 540, row_h: 14)
      col_w = width / cols.to_f
      (rows + 1).times { |i| sheet.line([left, top + i * row_h], [left + width, top + i * row_h], width: 0.4) }
      (cols + 1).times { |j| sheet.line([left + j * col_w, top], [left + j * col_w, top + rows * row_h], width: 0.4) }
      rows.times do |i|
        cols.times do |j|
          sheet.text(format("%.2f", rng.rand * 1000), at: [left + j * col_w + 2, top + i * row_h + 3], width: col_w - 4,
            size: 7, font: :mono, align: :right)
        end
      end
    end

    def vertical_bars(s, rng)
      s.caption("No barcodes: ruler, histogram, hatching, zebra columns, bar-like text.")
      # Ruler: ticks every 1/16 inch with 1/8, 1/4, 1/2 and 1 inch marks longer.
      x = 36.0
      i = 0
      while x <= 576
        len = [[16, 18], [8, 12], [4, 9], [2, 7]].find { |step, _| (i % step).zero? }&.last || 4
        s.line([x, 50], [x, 50 + len], width: 0.5)
        x += 4.5
        i += 1
      end
      # Histogram with thin bars.
      s.line([36, 230], [576, 230], width: 0.5)
      90.times do |b|
        h = 20 + rng.rand(110)
        s.rect([40 + b * 6, 230 - h], 3.5, h, gray: "000000")
      end
      # Vertical hatching (regular) and a hatch with two alternating widths.
      60.times { |k| s.rect([36 + k * 4, 260], 2, 70, gray: "000000") }
      50.times { |k| s.rect([300 + k * 5.5, 260], k.even? ? 1.5 : 3, 70, gray: "000000") }
      # Zebra columns (a table with shaded alternate columns).
      12.times do |k|
        s.rect([36 + k * 45, 360], 45, 160, gray: k.even? ? "DDDDDD" : "FFFFFF")
        s.line([36 + k * 45, 360], [36 + k * 45, 520], width: 0.5)
        10.times { |r| s.text(rng.rand(1000).to_s, at: [38 + k * 45, 366 + r * 15], width: 41, size: 7, font: :mono, align: :right) }
      end
      # Text made of vertical strokes.
      bars = Array.new(8) { Array.new(rng.rand(40..70)) { %w[| l I 1 ! i].sample(random: rng) }.join }
      bars.each_with_index { |t, k| s.text(t, at: [36, 540 + k * 16], size: 11, font: k.even? ? :mono : :sans) }
      # Piano keyboard.
      36.times do |k|
        s.rect([36 + k * 15, 690], 15, 70, stroke: true)
        s.rect([36 + k * 15 + 10, 690], 9, 44, gray: "000000") unless [2, 6].include?(k % 7) || k == 35
      end
    end

    # --- limits ----------------------------------------------------------------------------------------------------

    def limits
      name = "huge_page_14400pt.pdf"
      size = [14_400.0, 14_400.0]
      s = Sheet.new("Huge page 14400 x 14400 pt", page_size: size)
      s.text("200 x 200 inch page (the PDF 1.x maximum)", at: [720, 720], width: 8000, size: 144)
      s.qr("ZXF huge page QR", center: [3600, 3600], module_size: 48)
      s.render(out(name))
      entry(name, category: "limits", expected: s.codes.map { |c| expected(c) },
        notes: "MediaBox 14400 x 14400 pt: 60000 x 60000 px (3.6 GP) at 300 dpi. With max_pixels 64 MP the scanner " \
               "must lower the DPI to <= 40 before rendering (8000 x 8000 px) and record it; the 1200 pt QR " \
               "(48 pt modules = 26 px at 40 dpi) is still found.")

      name = "huge_banner_14400x1000pt.pdf"
      size = [14_400.0, 1000.0]
      s = Sheet.new("Huge banner page 14400 x 1000 pt", page_size: size)
      s.text("Banner page, 200 x 13.9 inches", at: [300, 100], width: 6000, size: 60)
      s.zint("code_128", "code128", "ZXF-BANNER-128", center: [10_800, 600], module_size: 4, height: 50)
      s.render(out(name))
      entry(name, category: "limits", expected: s.codes.map { |c| expected(c) },
        notes: "Non-square huge page: 60000 x 4167 px (250 MP) at 300 dpi; the 64 MP cap lowers the DPI to <= 151 " \
               "(pixels = (w/72*dpi) * (h/72*dpi)). Code 128 with 4 pt modules stays readable.")

      name = "huge_page_1000000pt.pdf"
      size = [1_000_000.0, 1_000_000.0]
      s = Sheet.new("Absurd page 1000000 x 1000000 pt", page_size: size)
      s.qr("ZXF absurd page QR", center: [200_000, 200_000], module_size: 500)
      s.render(out(name))
      entry(name, category: "limits", expected: s.codes.map { |c| expected(c) },
        notes: "MediaBox 1e6 x 1e6 pt (beyond Acrobat's 14400 limit; pdfinfo prints \"1e+06 x 1e+06 pts\"). The cap " \
               "needs a fractional DPI (8000 px / 13889 in = 0.576 dpi; pdftoppm -r 0.576 works): truncating to an " \
               "integer gives 0 (invalid) and rounding up to 1 exceeds max_pixels (193 MP). The 12.5k pt QR (500 pt " \
               "modules = 4 px at 0.576 dpi) is readable.")

      name = "userunit_10.pdf"
      size = [1440.0, 1440.0]
      s = Sheet.new("MediaBox 1440 x 1440 with /UserUnit 10", page_size: size)
      s.text("MediaBox 1440 x 1440 user units, /UserUnit 10 (= 14400 x 14400 pt physical)", at: [60, 60], width: 1300,
        size: 30)
      s.qr("ZXF UserUnit QR", center: [900, 900], module_size: 12)
      s.set_page_entry(:UserUnit, 10.0)
      s.pdf.renderer.min_version(1.6)
      s.render(out(name))
      entry(name, category: "limits", expected: s.codes.map { |c| expected(c) },
        notes: "/UserUnit 10 on a 1440 x 1440 MediaBox. Poppler 26.07 ignores UserUnit (pdfinfo: 1440 x 1440 pts; " \
               "pdftoppm -r 300 renders 6000 x 6000 = 36 MP, under the cap), so centers are in user units as Poppler " \
               "reports them. MuPDF and Ghostscript honor it (10x larger: 60000 x 60000 px at 300 dpi) - a loader " \
               "that honors UserUnit must use the same size for the pixel-cap estimate and page_position.")
    end
  end

  def self.write_manifest(entries)
    header = <<~YAML
      # GENERATED by script/fixtures/pdfs.rb - edit the script (expectations and EFFORT live there), not this file.
      # Schema: test/fixtures/README.md. Centers are PDF points from the top-left of the displayed page.
    YAML
    # A JSON round trip gives every entry its own objects, so Psych emits no &anchors/*aliases for shared arrays.
    tree = Psych.parse_stream(YAML.dump(JSON.parse(JSON.generate(entries))))
    tree.each do |node|
      next unless node.is_a?(Psych::Nodes::Sequence) || node.is_a?(Psych::Nodes::Mapping)
      next unless node.children.all?(Psych::Nodes::Scalar)

      # center: [x, y] and options: {password: ...} on one line, as in the README.
      node.style = node.is_a?(Psych::Nodes::Sequence) ? Psych::Nodes::Sequence::FLOW : Psych::Nodes::Mapping::FLOW
    end
    FileUtils.mkdir_p(File.dirname(MANIFEST))
    File.write(MANIFEST, header + tree.to_yaml)
  end

  def self.main
    Dir.mktmpdir("zxf-pdfs") do |tmp|
      stage = File.join(tmp, "out")
      FileUtils.mkdir_p(stage)
      entries = Corpus.new(tmp, stage).build
      # Committed files are replaced only after every fixture was built, so a failing run never leaves the PDFs and
      # the manifest out of step.
      FileUtils.mkdir_p(OUT_DIR)
      names = entries.map { |e| File.basename(e["file"]) }
      (Dir[File.join(OUT_DIR, "*.pdf")].map { |f| File.basename(f) } - names).each { |f| File.delete(File.join(OUT_DIR, f)) }
      names.each do |name|
        target = File.join(OUT_DIR, name)
        FileUtils.cp(File.join(stage, name), target) unless File.exist?(target) && FileUtils.compare_file(File.join(stage, name), target)
      end
      write_manifest(entries)
      bytes = entries.sum { |e| File.size(File.join(ROOT, "test", "fixtures", e["file"])) }
      puts "Wrote #{entries.size} PDFs to #{OUT_DIR} (#{(bytes / 1024.0).round} KiB) and #{MANIFEST}"
    end
  end
end

PdfFixtures.main if $PROGRAM_NAME == __FILE__
