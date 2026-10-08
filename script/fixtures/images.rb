#!/usr/bin/env ruby
# frozen_string_literal: true

# Raster image corpus: writes test/fixtures/images/** and the manifest fragment
# test/fixtures/manifest.d/images.yml. Dev only; the outputs are committed.
#
#   mise exec -- bundle exec ruby script/fixtures/images.rb
#   mise exec -- bundle exec script/generate_fixtures images    # also rebuilds test/fixtures/manifest.yml
#
# Encoders are independent of zxing-cpp: rqrcode for QR, zint for every other symbology. Scenes are composed and
# encoded with libvips (ruby-vips); tiffcp (libtiff tools) writes CCITT G3 and joins the mixed multi-page TIFF;
# ImageMagick (`magick`) writes the BMPs. Output is deterministic: fixed noise seeds, metadata stripped, no
# timestamps. Regenerating with other versions of libvips/libjpeg/x265/zint may change bytes, not expectations.
#
# Expectations: `center` is in pixels of the image *as displayed* (after EXIF/TIFF orientation and non-square pixel
# correction), in continuous coordinates (pixel (i, j) covers [i, i+1) x [j, j+1)), computed from where
# each symbol was placed and how the scene was transformed afterwards. `rotation` is degrees clockwise as displayed;
# it is omitted for linear codes at non-right angles (the reported value then depends on the pass that found the
# code). Compare rotations modulo 360 with a few degrees of slack. `effort` is a best guess, to be calibrated
# against the real scanner.

require "fileutils"
require "open3"
require "rqrcode"
require "tmpdir"
require "vips"
require "yaml"
require "zlib"

module ImageFixtures
  ROOT = File.expand_path("../..", __dir__)
  OUT = File.join(ROOT, "test", "fixtures", "images")
  FRAGMENT = File.join(ROOT, "test", "fixtures", "manifest.d", "images.yml")

  LINEAR = %w[code_128 ean_13].freeze
  ZINT_TYPES = {
    "data_matrix" => "DATAMATRIX", "code_128" => "CODE128", "ean_13" => "EAN13", "pdf417" => "PDF417",
    "aztec" => "AZTEC"
  }.freeze
  PALETTE = [[250, 245, 200], [25, 35, 95], [200, 40, 40], [40, 150, 70]].freeze # paper, ink, red, green
  WORDS = %w[
    lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor incididunt ut labore et dolore magna
    aliqua enim ad minim veniam quis nostrud exercitation ullamco laboris nisi aliquip ex ea commodo consequat duis aute
    irure in reprehenderit voluptate velit esse cillum eu fugiat nulla pariatur excepteur sint occaecat cupidatat non
    proident sunt culpa qui officia deserunt mollit anim id est laborum
  ].freeze

  module_function

  # EAN-13 with its check digit appended to the 12-digit +body+.
  def ean13(body)
    sum = body.chars.each_with_index.sum { |c, i| c.to_i * (i.even? ? 1 : 3) }
    body + ((10 - sum % 10) % 10).to_s
  end

  # Maps a gray image (0 = ink, 255 = paper) to RGB with the given ink and paper colours.
  def colorize(gray, ink: [0, 0, 0], paper: [255, 255, 255])
    gray.linear(paper.zip(ink).map { |p, i| (p - i) / 255.0 }, ink).cast(:uchar).copy(interpretation: :srgb)
  end

  # Maps a gray image (0 = ink, 255 = paper) to the given ink and paper gray levels.
  def levels(gray, ink, paper)
    gray.linear((paper - ink) / 255.0, ink).cast(:uchar)
  end

  def tiff_res(xdpi, ydpi = xdpi)
    {resunit: :inch, xres: xdpi / 25.4, yres: ydpi / 25.4}
  end

  def png_chunk(type, data)
    [data.bytesize].pack("N") + type + data + [Zlib.crc32(type + data)].pack("N")
  end

  # A PNG built by hand: +idat+ is the (possibly truncated) zlib stream; chunks get correct CRCs.
  def png_bytes(width, height, bit_depth:, color_type:, idat:, plte: nil, trns: nil)
    ihdr = [width, height, bit_depth, color_type, 0, 0, 0].pack("NNC5")
    out = "\x89PNG\r\n\x1a\n".b + png_chunk("IHDR", ihdr)
    out << png_chunk("PLTE", plte.flatten.pack("C*")) if plte
    out << png_chunk("tRNS", trns.pack("C*")) if trns
    out << png_chunk("IDAT", idat) << png_chunk("IEND", "")
  end

  # Packs 8-bit sample rows (a String of width * height bytes) into PNG scanlines of +bits+ per sample (filter 0).
  def png_scanlines(samples, width, bits)
    per_byte = 8 / bits
    samples.bytes.each_slice(width).map do |row|
      "\x00".b + row.each_slice(per_byte).map { |group|
        group.each_with_index.sum { |v, i| v << (8 - bits * (i + 1)) }
      }.pack("C*")
    end.join
  end

  # A rendered symbol: a 1-band uchar image (black ink on white, quiet zone included) and the box, in that image,
  # that a reader should report ([x0, y0, x1, y1], continuous pixel coordinates).
  Code = Data.define(:image, :box, :format, :text) do
    def center = [(box[0] + box[2]) / 2.0, (box[1] + box[3]) / 2.0]

    def width = box[2] - box[0]

    def height = box[3] - box[1]

    def linear? = LINEAR.include?(format)

    # 2D readers report the symbol corners. Linear readers report the span of the scan lines that decoded, which
    # can be any band of the bars (a few lines near the top on noisy scans), so allow half the bar height.
    def tolerance
      linear? ? [10, 0.5 * height].max.round : [6, 0.06 * [width, height].max].max.round
    end

    def inverted = with(image: image.invert)

    # Resamples the symbol, e.g. 0.5 turns 3 px modules into anti-aliased 1.5 px modules.
    def scaled(factor)
      resized = image.resize(factor)
      sx = resized.width.to_f / image.width
      sy = resized.height.to_f / image.height
      with(image: resized, box: [box[0] * sx, box[1] * sy, box[2] * sx, box[3] * sy])
    end
  end

  # Where a code ended up in a scene; updated by every geometric transform of the scene.
  Mark = Struct.new(:format, :text, :x, :y, :rotation, :tolerance, :linear, :page) do
    def to_expected
      entry = {"format" => format, "text" => text, "page" => page || 1, "center" => [x.round(1), y.round(1)],
               "tolerance" => tolerance}
      entry["rotation"] = rotation % 360 if !linear || (rotation % 90).zero?
      entry
    end
  end

  # A gray page (1-band uchar) plus the marks of the codes placed on it.
  class Scene
    attr_accessor :image
    attr_reader :marks, :paper, :dpi

    def initialize(width, height, paper: 255, dpi: 150)
      @paper = paper
      @dpi = dpi
      @image = Vips::Image.black(width, height).new_from_image(paper).cast(:uchar)
      @marks = []
    end

    def width = @image.width

    def height = @image.height

    # The image with its resolution recorded (vips stores pixels per mm); +dpi+ overrides it after a resize.
    def output(dpi: self.dpi) = @image.copy(xres: dpi / 25.4, yres: dpi / 25.4)

    def expected(page: nil)
      @marks.map do |m|
        m.page = page if page
        m.to_expected
      end
    end

    # Inserts +code+ with the top-left of its image at (x, y). With blend: true the code's white paper takes the
    # tone of what is underneath (printed on the page rather than a white sticker).
    def place(code, x, y, blend: false, tolerance: nil)
      x = x.round
      y = y.round
      if x.negative? || y.negative? || x + code.image.width > width || y + code.image.height > height
        raise ArgumentError, "#{code.text.inspect} does not fit at #{x},#{y} in #{width}x#{height}"
      end

      patch = code.image
      if blend
        under = @image.crop(x, y, patch.width, patch.height)
        patch = (under < patch).ifthenelse(under, patch)
      end
      @image = @image.insert(patch, x, y)
      cx, cy = code.center
      @marks << Mark.new(format: code.format, text: code.text, x: x + cx, y: y + cy, rotation: 0,
        tolerance: tolerance || code.tolerance, linear: code.linear?)
      @marks.last
    end

    def place_centered(code, cx, cy, **opts)
      ox, oy = code.center
      place(code, cx - ox, cy - oy, **opts)
    end

    # Copies another scene (image and marks) into this one at (x, y).
    def paste(other, x, y)
      @image = @image.insert(other.image, x, y)
      other.marks.each do |m|
        copy = m.dup
        copy.x += x
        copy.y += y
        @marks << copy
      end
      self
    end

    # Renders +str+ (Pango, generic font families so it works on macOS and Linux) with its top-left at (x, y).
    # Returns the height of the rendered text.
    def text(str, x, y, pt: 10, font: "sans", ink: 0, width: nil, dpi: self.dpi)
      opts = {font: "#{font} #{pt}", dpi: dpi}
      opts[:width] = width if width
      mask = Vips::Image.text(str.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;"), **opts)
      w = [mask.width, self.width - x].min
      h = [mask.height, height - y].min
      under = @image.crop(x, y, w, h)
      @image = @image.insert(mask.crop(0, 0, w, h).ifthenelse(ink, under, blend: true).cast(:uchar), x, y)
      mask.height
    end

    def draw(&)
      @image = @image.mutate(&)
      self
    end

    # Rotates by a multiple of 90 degrees clockwise (exact, no resampling).
    def rot90(turns)
      w = width
      h = height
      turns %= 4
      @image = @image.rot(%i[d0 d90 d180 d270][turns])
      @marks.each do |m|
        m.x, m.y = [[m.x, m.y], [h - m.y, m.x], [w - m.x, h - m.y], [m.y, w - m.x]][turns]
        m.rotation = (m.rotation + 90 * turns) % 360
      end
      self
    end

    # Rotates clockwise by any angle about the centre; the canvas grows to fit and the corners get paper colour.
    def rotate(degrees)
      w = width
      h = height
      @image = @image.rotate(degrees, background: [paper])
      t = degrees * Math::PI / 180
      @marks.each do |m|
        dx = m.x - w / 2.0
        dy = m.y - h / 2.0
        m.x = dx * Math.cos(t) - dy * Math.sin(t) + width / 2.0
        m.y = dx * Math.sin(t) + dy * Math.cos(t) + height / 2.0
        m.rotation = (m.rotation + degrees) % 360
      end
      self
    end

    def resize(hscale, vscale = hscale)
      w = width
      h = height
      @image = @image.resize(hscale, vscale: vscale)
      @marks.each do |m|
        m.x *= width.to_f / w
        m.y *= height.to_f / h
      end
      self
    end

    def blur(sigma)
      @image = @image.gaussblur(sigma)
      self
    end

    def noise(sigma, seed:)
      @image = (@image + Vips::Image.gaussnoise(width, height, sigma: sigma, mean: 0, seed: seed)).cast(:uchar)
      self
    end

    def threshold(level = 128)
      @image = (@image > level).cast(:uchar)
      self
    end
  end

  class Generator
    include ImageFixtures

    def run
      @entries = []
      @seq = 0
      FileUtils.rm_rf(OUT)
      FileUtils.mkdir_p(OUT)
      Dir.mktmpdir("zxing-ffi-images") do |tmp|
        @tmp = tmp
        clean
        rotation
        exif
        alpha
        bit_depth
        color
        palette
        multipage
        fax
        inverted
        tiny
        multi
        degraded
        false_positive
        limits
      end
      write_fragment
      report
    end

    private

    # --- helpers -------------------------------------------------------------------------------------------------

    def path(file) = File.join(OUT, file)

    def tmp(ext) = File.join(@tmp, "t#{@seq += 1}.#{ext}")

    def run!(*argv)
      out, err, status = Open3.capture3(*argv)
      raise "#{argv.join(" ")} failed (#{status.exitstatus}): #{err}" unless status.success?

      out
    end

    def add(file, category:, kind:, effort:, expected:, notes:, requires: [], options: {}, expect_error: nil)
      raise "missing #{file}" unless File.exist?(path(file))

      @entries << {
        "file" => "images/#{file}", "category" => category, "kind" => kind, "requires" => requires,
        "effort" => effort, "options" => options, "expect_error" => expect_error, "expected" => expected,
        "notes" => notes
      }
    end

    def qr(text, module_px:, level: :m, quiet: 4)
      modules = RQRCode::QRCode.new(text, level: level).modules
      n = modules.size
      side = (n + 2 * quiet) * module_px
      white = "\xFF".b
      margin = white * (quiet * module_px)
      rows = modules.map do |row|
        (margin + row.map { |dark| (dark ? "\x00".b : white) * module_px }.join + margin) * module_px
      end
      blank = white * (side * quiet * module_px)
      image = Vips::Image.new_from_memory_copy(blank + rows.join + blank, side, side, 1, :uchar)
      offset = quiet * module_px
      Code.new(image: image, box: [offset, offset, offset + n * module_px, offset + n * module_px],
        format: "qr_code", text: text)
    end

    # zint renders at 2 px per module per unit of --scale. Quiet zones are added here (10X linear, 3X matrix).
    def zint(format, data, module_px:, height: nil)
      file = tmp("png")
      argv = ["zint", "-b", ZINT_TYPES.fetch(format), "--scale=#{module_px / 2.0}", "--notext", "-o", file]
      argv << "--height=#{height}" if height
      argv << "--square" if format == "data_matrix"
      argv << "--guarddescent=0" if format == "ean_13"
      _, err, status = Open3.capture3(*argv, "-d", data)
      raise "zint #{format} #{data.inspect} failed: #{err}" if status.exitstatus > 4 || !File.exist?(file)

      image = Vips::Image.new_from_file(file).extract_band(0).copy_memory
      left, top, w, h = image.find_trim(threshold: 128, background: [255])
      pad = (LINEAR.include?(format) ? 10 : 3) * module_px
      image = image.embed(pad, pad, image.width + 2 * pad, image.height + 2 * pad, extend: :white)
      text = (format == "ean_13") ? ean13(data) : data
      Code.new(image: image, box: [left + pad, top + pad, left + pad + w, top + pad + h], format: format, text: text)
    end

    def write_pnm(file, magic, image, maxval: 255)
      data = image.write_to_memory
      data = data.unpack("S*").pack("n*") if maxval > 255
      File.binwrite(path(file), "#{magic}\n#{image.width} #{image.height}\n#{maxval}\n" + data)
    end

    def write_pbm(file, gray)
      rows = gray.write_to_memory.bytes.each_slice(gray.width).map do |row|
        [row.map { |v| (v < 128) ? "1" : "0" }.join].pack("B*")
      end
      File.binwrite(path(file), "P4\n#{gray.width} #{gray.height}\n" + rows.join)
    end

    # ImageMagick is only used for BMP (libvips cannot write it). BMP carries no metadata or timestamps.
    def write_bmp(rgb, file, type:)
      src = tmp("png")
      rgb.pngsave(src, keep: :none)
      run!("magick", "png:#{src}", "-type", type, "BMP3:#{path(file)}")
    end

    def write_png_palette(file, indices, plte:, bits:, trns: nil)
      scanlines = png_scanlines(indices.write_to_memory, indices.width, bits)
      File.binwrite(path(file), png_bytes(indices.width, indices.height, bit_depth: bits, color_type: 3,
        idat: Zlib::Deflate.deflate(scanlines, Zlib::BEST_COMPRESSION), plte: plte, trns: trns))
    end

    def pseudo_text(rng, words)
      Array.new(words) do
        case rng.rand(100)
        when 0..5 then format("%05d", rng.rand(100_000))
        when 6..9 then format("%d.%02d", rng.rand(10_000), rng.rand(100))
        when 10..11 then format("2026-%02d-%02d", rng.rand(1..12), rng.rand(1..28))
        when 12 then format("REF-%06d", rng.rand(1_000_000))
        else WORDS[rng.rand(WORDS.size)]
        end
      end.join(" ")
    end

    # --- clean: one baseline per container format -----------------------------------------------------------------

    # Two codes side by side: QR (6 px modules) and Code 128 (3 px X-dimension); the width follows the payloads.
    # compact: 4 px QR modules and a 2 px X-dimension, for uncompressed formats (BMP, PNM) to stay small.
    def label_scene(qr_text, c128_text, dpi: 150, compact: false)
      left = qr(qr_text, module_px: compact ? 4 : 6)
      right = zint("code_128", c128_text, module_px: compact ? 2 : 3, height: 25)
      height = compact ? 180 : 340
      scene = Scene.new(20 + left.image.width + 20 + right.image.width + 20, height, dpi: dpi)
      scene.place(left, 20, (height - left.image.height) / 2)
      scene.place(right, 40 + left.image.width, (height - right.image.height) / 2)
      scene
    end

    CLEAN = [
      # label, extension, kind, requires, notes
      ["png", "png", "png", [], "8-bit RGB PNG"],
      ["jpeg", "jpg", "jpeg", [], "RGB baseline JPEG, q90, no JFIF/EXIF"],
      ["gif", "gif", "gif", [], "GIF89a, 2-colour palette"],
      ["bmp", "bmp", "bmp", [], "24-bit BMP3 (BITMAPINFOHEADER); needs ImageMagick (libvips has no BMP loader)"],
      ["webp", "webp", "webp", [], "lossy WebP q90"],
      ["tiff", "tif", "tiff", [], "single-page RGB TIFF, LZW"],
      ["pgm", "pgm", "pnm", [], "P5 8-bit"],
      ["ppm", "ppm", "pnm", [], "P6 8-bit RGB"],
      ["pbm", "pbm", "pnm", [], "P4 1-bit (1 = black); optional in the pure-Ruby PNM loader"],
      ["heic", "heic", "heif", ["heif"], "HEIC (HEVC, q90) written by libvips/libheif"],
      ["avif", "avif", "avif", ["avif"], "AVIF (AV1, q90) written by libvips/libheif"]
    ].freeze

    def clean
      CLEAN.each do |label, ext, kind, requires, notes|
        compact = %w[bmp pgm ppm pbm].include?(label) # uncompressed: 4 px QR modules, 2 px X-dimension
        scene = label_scene("zxing_ffi/clean_#{label}", "CLEAN-#{label.upcase}", compact: compact)
        file = "clean_#{label}.#{ext}"
        gray = scene.output
        rgb = colorize(gray)
        case label
        when "png" then rgb.pngsave(path(file), compression: 9, keep: :none)
        when "jpeg" then rgb.jpegsave(path(file), Q: 90, keep: :none)
        when "gif" then rgb.gifsave(path(file), keep: :none)
        when "bmp" then write_bmp(rgb, file, type: "TrueColor")
        when "webp" then rgb.webpsave(path(file), Q: 90, keep: :none)
        when "tiff" then rgb.tiffsave(path(file), compression: :lzw, keep: :none, **tiff_res(150))
        when "pgm" then write_pnm(file, "P5", gray)
        when "ppm" then write_pnm(file, "P6", rgb)
        when "pbm" then write_pbm(file, gray)
        when "heic" then rgb.heifsave(path(file), Q: 90, compression: :hevc, keep: :none)
        when "avif" then rgb.heifsave(path(file), Q: 90, compression: :av1, keep: :none)
        end
        size = compact ? "QR 4 px modules + Code 128 X 2 px" : "QR 6 px modules + Code 128 X 3 px"
        add(file, category: "clean", kind: kind, requires: requires, effort: "fast", expected: scene.expected,
          notes: "Baseline container: #{notes}. #{size} on white.")
      end

      scene = label_scene("zxing_ffi/clean_misnamed", "CLEAN-MISNAMED")
      colorize(scene.output).pngsave(path("clean_png_misnamed.jpg"), compression: 9, keep: :none)
      add("clean_png_misnamed.jpg", category: "clean", kind: "png", effort: "fast", expected: scene.expected,
        notes: "PNG data with a .jpg extension: the type must come from magic bytes, never the extension.")
    end

    # --- rotation -------------------------------------------------------------------------------------------------

    def rotation_code(name, tag)
      case name
      when "qr" then qr("zxing_ffi/qr_rot#{tag}", module_px: 6)
      when "datamatrix" then zint("data_matrix", "zxing_ffi/datamatrix_rot#{tag}", module_px: 6)
      when "code128" then zint("code_128", "ROT#{tag}-C128", module_px: 3, height: 50)
      when "ean13" then zint("ean_13", "20000000#{tag}1", module_px: 3, height: 50)
      end
    end

    def rotation
      %w[qr datamatrix code128 ean13].each do |name|
        [0, 90, 180, 270, 30, 45].each do |angle|
          tag = format("%03d", angle)
          code = rotation_code(name, tag)
          right = (angle % 90).zero?
          scene = Scene.new(720, 520)
          scene.place_centered(code, 290, 230)
          scene.text("rotation fixture: #{name}, #{angle} degrees clockwise", 24, 470, pt: 9)
          right ? scene.rot90(angle / 90) : scene.rotate(angle)
          file = "#{name}_rot#{tag}.png"
          scene.output.pngsave(path(file), compression: 9, keep: :none)
          effort = (code.linear? && !right) ? "thorough" : "fast"
          notes = if right
            "Whole page rotated #{angle} deg clockwise (exact); try_rotate covers it."
          elsif code.linear?
            "Page rotated #{angle} deg (bilinear, white fill). Bars are #{code.height.fdiv(code.width).round(2)}x as " \
              "tall as the symbol is wide, so no horizontal or vertical scan line crosses the whole symbol: found " \
              "by the rotated_45 pass. Rotation omitted (pass-dependent)."
          else
            "Page rotated #{angle} deg (bilinear, white fill); 2D detectors are rotation invariant."
          end
          add(file, category: "rotation", kind: "png", effort: effort, expected: scene.expected, notes: notes)
        end
      end
    end

    # --- EXIF / TIFF orientation ----------------------------------------------------------------------------------

    # Photo-like frame: vignetted gray background, a sheet of paper with a soft shadow, a QR and a Code 128 printed
    # on it, slight blur and sensor noise.
    def photo_scene(width, height, tag, seed:)
      scene = Scene.new(width, height, dpi: 72)
      xyz = Vips::Image.xyz(width, height)
      dx = xyz[0] - width / 2.0
      dy = xyz[1] - height / 2.0
      r2 = (dx * dx + dy * dy) / ((width / 2.0)**2 + (height / 2.0)**2)
      background = (r2 * -55 + 175).cast(:uchar)
      sx = (width * 0.12).round
      sy = (height * 0.1).round
      sw = (width * 0.76).round
      sh = (height * 0.78).round
      shadow = Vips::Image.black(width, height).mutate { |m| m.draw_rect!(255, sx + 14, sy + 18, sw, sh, fill: true) }
      background = (background * (shadow.gaussblur(12) * (-0.35 / 255) + 1)).cast(:uchar)
      scene.image = background.mutate { |m| m.draw_rect!(236, sx, sy, sw, sh, fill: true) }
      scene.text("Photo fixture #{tag}", sx + 30, sy + 24, pt: 16, ink: 45)
      scene.place_centered(qr("zxing_ffi/#{tag}", module_px: 8), width / 2, sy + sh * 0.36, blend: true)
      scene.place_centered(zint("code_128", tag.upcase.tr("_", "-"), module_px: 3, height: 40), width / 2,
        sy + sh * 0.76, blend: true)
      scene.blur(0.8).noise(4, seed: seed)
    end

    # Stored pixels for an EXIF orientation: the inverse of the transform a viewer applies.
    def stored_pixels(image, orientation)
      case orientation
      when 3 then image.rot(:d180)
      when 6 then image.rot(:d270) # viewer rotates 90 clockwise
      when 8 then image.rot(:d90) # viewer rotates 90 counter-clockwise
      when 5 then image.rot(:d90).flip(:horizontal) # transpose (its own inverse)
      end
    end

    def check_orientation(file, displayed)
      shown = Vips::Image.new_from_file(path(file)).autorot
      return if [shown.width, shown.height] == [displayed.width, displayed.height]

      raise "#{file}: autorot gives #{shown.width}x#{shown.height}"
    end

    def exif
      {6 => "phone portrait shot (stored landscape, viewer rotates 90 cw)",
       8 => "stored rotated the other way (viewer rotates 90 ccw)",
       3 => "upside-down landscape (viewer rotates 180)",
       5 => "transposed (mirror + rotate); rare but part of the EXIF contract"}.each do |orientation, what|
        width, height = (orientation == 3) ? [1200, 900] : [900, 1200]
        tag = "exif_orient#{orientation}"
        scene = photo_scene(width, height, tag, seed: 40 + orientation)
        file = "#{tag}.jpg"
        stored = stored_pixels(scene.image, orientation).copy(xres: 72 / 25.4, yres: 72 / 25.4)
        stored = stored.mutate { |m| m.set_type!(GObject::GINT_TYPE, "orientation", orientation) }
        stored.jpegsave(path(file), Q: 85, keep: [:exif])
        check_orientation(file, scene.image)
        add(file, category: "exif", kind: "jpeg", effort: "fast", expected: scene.expected,
          notes: "EXIF Orientation=#{orientation}: #{what}. Photo-like (vignette, blur, noise), q85. Centers and " \
            "rotation are in displayed coordinates (#{width}x#{height}); ignoring the tag misplaces them.")
      end

      # A scanner that stores the page sideways and says so in the TIFF Orientation tag (274).
      scene = Scene.new(850, 1100, dpi: 100)
      scene.text("Scanned sideways; TIFF Orientation = 6", 60, 60, pt: 14)
      scene.text(pseudo_text(Random.new(7), 90), 60, 130, pt: 10, width: 730)
      scene.place_centered(qr("zxing_ffi/tiff_orient6", module_px: 6), 250, 620)
      scene.place_centered(zint("code_128", "TIFF-ORIENT6", module_px: 3, height: 30), 560, 900)
      file = "tiff_orient6.tif"
      stored = Vips::Image.new_from_memory_copy(stored_pixels(scene.image, 6).write_to_memory, 1100, 850, 1, :uchar)
      stored = stored.mutate { |m| m.set_type!(GObject::GINT_TYPE, "orientation", 6) }
      stored.tiffsave(path(file), compression: :deflate, keep: :none, **tiff_res(100))
      check_orientation(file, scene.image)
      add(file, category: "exif", kind: "tiff", effort: "fast", expected: scene.expected,
        notes: "Stored 1100x850 with TIFF Orientation=6 (not EXIF); displayed 850x1100 portrait page.")
    end

    # --- alpha ----------------------------------------------------------------------------------------------------

    def alpha
      scene = label_scene("zxing_ffi/alpha_rgba", "ALPHA-RGBA")
      opacity = scene.output.invert
      zero = opacity.new_from_image(0)
      Vips::Image.bandjoin([zero, zero, zero, opacity]).copy(interpretation: :srgb)
        .pngsave(path("alpha_rgba_black_transparent.png"), compression: 9, keep: :none)
      add("alpha_rgba_black_transparent.png", category: "alpha", kind: "png", effort: "fast",
        expected: scene.expected,
        notes: "RGBA PNG: every pixel is RGB black; ink alpha 255, background alpha 0 (transparent pixels stored " \
          "as black). Dropping alpha gives an all-black page; flatten onto white.")

      scene = label_scene("zxing_ffi/alpha_gray", "ALPHA-GRAY")
      opacity = scene.output.invert
      Vips::Image.bandjoin([opacity.new_from_image(0), opacity]).copy(interpretation: :b_w)
        .pngsave(path("alpha_gray_alpha.png"), compression: 9, keep: :none)
      add("alpha_gray_alpha.png", category: "alpha", kind: "png", effort: "fast", expected: scene.expected,
        notes: "Gray+alpha PNG (colour type 4): gray 0 everywhere, background alpha 0.")

      scene = label_scene("zxing_ffi/alpha_palette", "ALPHA-PALETTE")
      write_png_palette("alpha_palette_trns.png", (scene.output < 128).ifthenelse(1, 0).cast(:uchar),
        plte: [[0, 0, 0], [20, 20, 60]], trns: [0], bits: 1)
      add("alpha_palette_trns.png", category: "alpha", kind: "png", effort: "fast", expected: scene.expected,
        notes: "1-bit palette PNG with tRNS: index 0 = black, fully transparent; index 1 = navy ink.")

      scene = label_scene("zxing_ffi/alpha_webp", "ALPHA-WEBP")
      opacity = scene.output.invert
      zero = opacity.new_from_image(0)
      Vips::Image.bandjoin([zero, zero, zero, opacity]).copy(interpretation: :srgb)
        .webpsave(path("alpha_webp_black_transparent.webp"), lossless: true, exact: true, keep: :none)
      add("alpha_webp_black_transparent.webp", category: "alpha", kind: "webp", effort: "fast",
        expected: scene.expected,
        notes: "Lossless WebP with alpha (exact: RGB of transparent pixels kept black).")
    end

    # --- bit depth ------------------------------------------------------------------------------------------------

    # 16-bit version of +gray+: the high byte carries the picture (ink/paper levels), the low byte a diagonal ramp.
    # Keeping the low byte yields stripes and clipping to 255 yields a blank page; only scaling (/257, >>8) works.
    def sixteen(gray, ink:, paper:)
      high = gray.linear(paper.zip(ink).map { |p, i| (p - i) / 255.0 }, ink).cast(:uchar).cast(:ushort)
      xyz = Vips::Image.xyz(gray.width, gray.height)
      low = ((xyz[0] * 7 + xyz[1] * 13) % 256).cast(:ushort)
      (high * 256 + low).cast(:ushort).copy(interpretation: (ink.size == 1) ? :grey16 : :rgb16)
    end

    def bit_depth
      scene = label_scene("zxing_ffi/depth16_gray", "DEPTH16-GRAY")
      sixteen(scene.output, ink: [16], paper: [232]).pngsave(path("depth16_gray.png"), bitdepth: 16,
        compression: 9, keep: :none)
      add("depth16_gray.png", category: "bit_depth", kind: "png", effort: "fast", expected: scene.expected,
        notes: "16-bit grayscale PNG; high byte = image, low byte = ramp (truncation/clipping both fail).")

      scene = label_scene("zxing_ffi/depth16_rgb", "DEPTH16-RGB")
      sixteen(scene.output, ink: [10, 20, 90], paper: [240, 235, 220]).pngsave(path("depth16_rgb.png"),
        bitdepth: 16, compression: 9, keep: :none)
      add("depth16_rgb.png", category: "bit_depth", kind: "png", effort: "fast", expected: scene.expected,
        notes: "16-bit RGB PNG, dark blue on cream; low bytes are a ramp.")

      scene = label_scene("zxing_ffi/depth16_tiff", "DEPTH16-TIFF")
      sixteen(scene.output, ink: [16], paper: [232]).tiffsave(path("depth16_gray.tif"), compression: :deflate,
        keep: :none, **tiff_res(150))
      add("depth16_gray.tif", category: "bit_depth", kind: "tiff", effort: "fast", expected: scene.expected,
        notes: "16-bit grayscale TIFF, deflate + predictor.")

      scene = label_scene("zxing_ffi/depth16_pgm", "DEPTH16-PGM", compact: true)
      write_pnm("depth16_gray.pgm", "P5", sixteen(scene.output, ink: [16], paper: [232]), maxval: 65_535)
      add("depth16_gray.pgm", category: "bit_depth", kind: "pnm", effort: "fast", expected: scene.expected,
        notes: "P5 maxval 65535 (big-endian samples, as the PNM spec requires); low bytes are a ramp.")

      scene = label_scene("zxing_ffi/depth16_maxval1000", "MAXVAL-1000", compact: true)
      write_pnm("depth16_maxval1000.pgm", "P5", scene.output.linear((922 - 63) / 255.0, 63).cast(:ushort),
        maxval: 1000)
      add("depth16_maxval1000.pgm", category: "bit_depth", kind: "pnm", effort: "fast", expected: scene.expected,
        notes: "P5 maxval 1000 (16-bit samples, ink 63, paper 922): must scale by maxval, not 65535.")

      scene = label_scene("zxing_ffi/depth1_png", "DEPTH1-PNG")
      scene.output.pngsave(path("depth1_gray.png"), bitdepth: 1, compression: 9, keep: :none)
      add("depth1_gray.png", category: "bit_depth", kind: "png", effort: "fast", expected: scene.expected,
        notes: "1-bit grayscale PNG (must become 0/255).")

      scene = label_scene("zxing_ffi/depth4_png", "DEPTH4-PNG")
      levels(scene.output, 17, 238).pngsave(path("depth4_gray.png"), bitdepth: 4, compression: 9, keep: :none)
      add("depth4_gray.png", category: "bit_depth", kind: "png", effort: "fast", expected: scene.expected,
        notes: "4-bit grayscale PNG (levels 1 and 14 of 15).")
    end

    # --- colour ---------------------------------------------------------------------------------------------------

    def cmyk(gray)
      ink = gray.invert
      Vips::Image.bandjoin([ink.new_from_image(20), ink.new_from_image(0), ink.new_from_image(38), ink])
        .copy(interpretation: :cmyk)
    end

    def color
      scene = label_scene("zxing_ffi/color_cmyk_jpeg", "CMYK-JPEG")
      cmyk(scene.output).jpegsave(path("color_cmyk.jpg"), Q: 90, keep: :none)
      add("color_cmyk.jpg", category: "color", kind: "jpeg", effort: "fast", expected: scene.expected,
        notes: "CMYK JPEG (Adobe APP14, inverted samples, no ICC profile), q90. The codes are in the K channel " \
          "only; C/M/Y carry a light paper tint.")

      scene = label_scene("zxing_ffi/color_cmyk_tiff", "CMYK-TIFF")
      cmyk(scene.output).tiffsave(path("color_cmyk.tif"), compression: :lzw, keep: :none, **tiff_res(150))
      add("color_cmyk.tif", category: "color", kind: "tiff", effort: "fast", expected: scene.expected,
        notes: "CMYK TIFF (Photometric=Separated, InkSet=CMYK), LZW; codes in K only.")

      scene = label_scene("zxing_ffi/color_red", "COLOR-RED")
      colorize(scene.output, ink: [255, 0, 0]).pngsave(path("color_red_on_white.png"), compression: 9, keep: :none)
      add("color_red_on_white.png", category: "color", kind: "png", effort: "fast", expected: scene.expected,
        notes: "Pure red ink on white: invisible in the R channel alone, luminance ~54 vs 255.")
    end

    # --- palette --------------------------------------------------------------------------------------------------

    # Palette indices for a label scene: 0 paper, 1 ink, 2 a red header band, 3 a green box. The palette is not
    # ordered by luminance, so reading indices as gray levels loses the codes.
    def palette_indices(gray)
      indices = (gray < 128).ifthenelse(1, 0).cast(:uchar)
      indices.mutate do |m|
        m.draw_rect!(2, 0, 0, gray.width, 36, fill: true)
        m.draw_rect!(3, gray.width - 90, gray.height - 56, 70, 40, fill: true)
      end
    end

    def palette_rgb(indices)
      lut = Vips::Image.new_from_memory_copy(PALETTE.flatten.pack("C*") + ("\x00".b * (3 * (256 - PALETTE.size))),
        256, 1, 3, :uchar)
      indices.maplut(lut).copy(interpretation: :srgb)
    end

    def palette
      scene = label_scene("zxing_ffi/palette_png", "PALETTE-PNG")
      write_png_palette("palette_png.png", palette_indices(scene.output), plte: PALETTE, bits: 2)
      add("palette_png.png", category: "palette", kind: "png", effort: "fast", expected: scene.expected,
        notes: "2-bit palette PNG: index 0 cream paper, 1 navy ink, 2 red, 3 green (indices are not gray levels).")

      scene = label_scene("zxing_ffi/palette_gif", "PALETTE-GIF")
      palette_rgb(palette_indices(scene.output)).gifsave(path("palette_gif.gif"), dither: 0, keep: :none)
      add("palette_gif.gif", category: "palette", kind: "gif", effort: "fast", expected: scene.expected,
        notes: "4-colour GIF: navy ink on cream with red and green decorations.")

      scene = label_scene("zxing_ffi/palette_bmp", "PALETTE-BMP")
      write_bmp(palette_rgb(palette_indices(scene.output)), "palette_bmp.bmp", type: "Palette")
      add("palette_bmp.bmp", category: "palette", kind: "bmp", effort: "fast",
        expected: scene.expected, notes: "4-bit palette BMP3 (ImageMagick picks 4 bpp for 4 colours), same colours as palette_png.")
    end

    # --- multi-page TIFF ------------------------------------------------------------------------------------------

    def multipage
      pages = Array.new(3) { Scene.new(850, 1100, dpi: 100) }
      pages[0].text("Page 1 of 3", 60, 50, pt: 16)
      pages[0].place_centered(qr("zxing_ffi/multipage_3p page 1", module_px: 6), 300, 420)
      pages[1].text("Page 2 of 3", 60, 50, pt: 16)
      pages[1].text("This page is intentionally left blank.", 220, 520, pt: 12)
      pages[2].text("Page 3 of 3", 60, 50, pt: 16)
      pages[2].place_centered(zint("code_128", "MP3P-PAGE3", module_px: 3, height: 30), 425, 300)
      pages[2].place_centered(zint("data_matrix", "zxing_ffi/multipage_3p page 3", module_px: 6), 600, 800)
      Vips::Image.arrayjoin(pages.map(&:image), across: 1)
        .tiffsave(path("multipage_3p.tif"), compression: :deflate, page_height: 1100, keep: :none, **tiff_res(100))
      add("multipage_3p.tif", category: "multipage", kind: "tiff", effort: "fast",
        expected: pages[0].expected(page: 1) + pages[2].expected(page: 3),
        notes: "3 pages, 850x1100 8-bit gray, deflate. Page 1: QR; page 2: no code; page 3: Code 128 + Data Matrix.")

      multipage_mixed
    end

    # Pages of different size, depth and compression; pages 1 and 3 carry the same QR at the same position.
    def multipage_mixed
      same_qr = qr("zxing_ffi/multipage_mixed", module_px: 6)
      first = Scene.new(1275, 1650, dpi: 150)
      first.text("Page 1: bilevel, CCITT G4", 80, 60, pt: 14)
      first.place_centered(same_qr, 400, 500)
      second = Scene.new(1100, 850, dpi: 100)
      second.draw { |m| m.draw_rect!(90, 0, 0, 1100, 90, fill: true) }
      second.text("Page 2: landscape RGB, JPEG-compressed, no barcode", 60, 140, pt: 14)
      third = Scene.new(1275, 1650, dpi: 150)
      third.text("Page 3: 8-bit gray, LZW", 80, 60, pt: 14)
      third.place_centered(same_qr, 400, 500)
      third.place_centered(zint("code_128", "MIXED-P3", module_px: 3, height: 30), 800, 1100)

      parts = [tmp("tif"), tmp("tif"), tmp("tif")]
      first.output.tiffsave(parts[0], compression: :ccittfax4, bitdepth: 1, miniswhite: true, keep: :none,
        **tiff_res(150))
      colorize(second.output, ink: [30, 60, 140], paper: [245, 240, 225])
        .tiffsave(parts[1], compression: :jpeg, Q: 85, keep: :none, **tiff_res(100))
      third.output.tiffsave(parts[2], compression: :lzw, keep: :none, **tiff_res(150))
      run!("tiffcp", *parts, path("multipage_mixed.tif"))
      add("multipage_mixed.tif", category: "multipage", kind: "tiff", effort: "fast",
        expected: first.expected(page: 1) + third.expected(page: 3),
        notes: "Pages differ: 1275x1650 1-bit G4 (MinIsWhite) / 1100x850 RGB JPEG-in-TIFF, no code / " \
          "1275x1650 gray LZW. Same QR at the same spot on pages 1 and 3 (dedupe is per page: keep both).")
    end

    # --- fax ------------------------------------------------------------------------------------------------------

    FAX_WIDTH = 1728 # 8.47 in at 204 dpi
    FAX_DESIGN_HEIGHT = 2244 # 11 in at 204 dpi (square pixels)

    def fax_page(tag, c128_text)
      scene = Scene.new(FAX_WIDTH, FAX_DESIGN_HEIGHT, dpi: 204)
      scene.text("FROM: ZXING-FFI LAB +1 555 0100    TO: +1 555 0199    2026-09-25 09:30    P.1/1", 40, 24, pt: 9,
        font: "monospace")
      scene.text("FAX", 150, 150, pt: 40, font: "sans bold")
      scene.text("To: Receiving department\nFrom: Test fixtures\nRe: #{tag}\nPages: 1 (including cover)", 150, 380,
        pt: 13)
      scene.place_centered(qr("zxing_ffi/#{tag}", module_px: 10), 450, 1050)
      scene.place_centered(zint("code_128", c128_text, module_px: 4, height: 30), 1200, 1050)
      scene.place_centered(zint("data_matrix", "zxing_ffi/#{tag}", module_px: 10), 450, 1650)
      scene.text(pseudo_text(Random.new(tag.sum), 120), 800, 1400, pt: 11, width: 800)
      scene
    end

    def fax
      [
        ["fax_g4_204x98.tif", 98, "g4", "CCITT G4, MinIsWhite"],
        ["fax_g3_204x98.tif", 98, "g3:1d:fill", "CCITT G3 1-D (Modified Huffman, EOL-aligned), FillOrder=2"],
        ["fax_g3_2d_204x98.tif", 98, "g3:2d:fill", "CCITT G3 2-D (T.4 MR), FillOrder=2"],
        ["fax_g4_204x196.tif", 196, "g4", "fine mode, CCITT G4"]
      ].each do |file, yres, compression, what|
        tag = File.basename(file, ".tif")
        scene = fax_page(tag, tag.delete_prefix("fax_").upcase.tr("_", "-"))
        rows = (FAX_DESIGN_HEIGHT * yres / 204.0).round
        # The fax machine samples the page at 204 x yres: squash vertically, then binarize.
        stored = scene.image.resize(1.0, vscale: rows.to_f / FAX_DESIGN_HEIGHT)
        raise "#{file}: #{stored.height} rows" unless stored.height == rows

        stored = (stored > 128).cast(:uchar)
        if compression == "g4"
          stored.tiffsave(path(file), compression: :ccittfax4, bitdepth: 1, miniswhite: true, keep: :none,
            **tiff_res(204, yres))
        else
          raw = tmp("tif")
          stored.tiffsave(raw, bitdepth: 1, miniswhite: true, keep: :none, **tiff_res(204, yres))
          run!("tiffcp", "-c", compression, "-f", "lsb2msb", raw, path(file))
        end
        if yres == 98
          notes = "#{what}; stored #{FAX_WIDTH}x#{rows} at 204x98 dpi (squashed ~2:1). The loader must resample y " \
            "by 204/98 to #{FAX_WIDTH}x#{FAX_DESIGN_HEIGHT}; centers were placed on that square-pixel page and " \
            "the stored raster is its vertical resampling, so they are in corrected coordinates."
        else
          # 204 vs 196 dpi differ by 3.9%, under the loaders' 5% threshold: no resampling expected, so the
          # expected centers are in stored-raster coordinates.
          scene.resize(1.0, rows.to_f / FAX_DESIGN_HEIGHT)
          notes = "#{what}; stored #{FAX_WIDTH}x#{rows} at 204x196 dpi. The resolutions differ by 3.9% (< 5%) " \
            "so no aspect correction is expected: centers are in stored coordinates (if a loader " \
            "corrects anyway, y grows by 4%)."
        end
        add(file, category: "fax", kind: "tiff", effort: "fast", expected: scene.expected, notes: notes)
      end
    end

    # --- inverted -------------------------------------------------------------------------------------------------

    def inverted
      {
        "qr" => -> { qr("zxing_ffi/inverted_qr", module_px: 7) },
        "datamatrix" => -> { zint("data_matrix", "zxing_ffi/inverted_datamatrix", module_px: 7) },
        "code128" => -> { zint("code_128", "INVERTED-C128", module_px: 3, height: 40) }
      }.each do |name, build|
        scene = Scene.new(640, 420)
        scene.text("White-on-black #{name}", 24, 16, pt: 11)
        scene.place_centered(build.call.inverted, 320, 225)
        file = "inverted_#{name}.png"
        scene.output.pngsave(path(file), compression: 9, keep: :none)
        what = "White modules on a black label (the quiet zone is black too) on a white page."
        if name == "code128"
          add(file, category: "inverted", kind: "png", effort: "normal", expected: scene.expected,
            notes: "#{what} zxing-cpp 3.1.1's try_invert does not cover linear symbologies, so the base pass misses " \
              "it; found by the inverted pass, which decodes a pixel-inverted copy for linear formats.")
        else
          add(file, category: "inverted", kind: "png", effort: "fast", expected: scene.expected,
            notes: "#{what} Found by the base pass: try_invert is on by default in zxing-cpp 3.1.")
        end
      end
    end

    # --- tiny codes on letter pages at 300 dpi --------------------------------------------------------------------

    def letter300(title, seed)
      scene = Scene.new(2550, 3300, dpi: 300)
      scene.text(title, 225, 200, pt: 18, font: "sans bold")
      y = 330
      rng = Random.new(seed)
      3.times do
        y += scene.text(pseudo_text(rng, 70), 225, y, pt: 10, width: 2100) + 60
      end
      scene.text("Page 1 of 1", 1175, 3080, pt: 9)
      scene
    end

    # Tiny codes on a US Letter page at 300 dpi. All are found by the base pass with zxing-cpp 3.1.1. Measured while
    # calibrating: at 1.3-1.7 px per module with smooth resampling, whether a code decodes flips with the payload and
    # sub-pixel phase. The 2x high_res pass (rasters < 2000 px only) rescued none of the misses while it replicated
    # pixels; now that it upscales bicubically it finds most of them (tiny_upscale, on a page small enough for it).
    def tiny
      [
        ["tiny_qr_1_5px.png", "QR, 1.5 px modules (rendered at 3 px, box-downsampled 2x: anti-aliased)",
          -> { qr("ZXF TINY QR 1.5", module_px: 3).scaled(0.5) }, [2150, 2900]],
        ["tiny_qr_2px.png", "QR, 2 px modules", -> { qr("ZXF TINY QR 2PX", module_px: 2) }, [400, 2950]],
        ["tiny_datamatrix_2px.png", "Data Matrix, 2 px modules",
          -> { zint("data_matrix", "ZXF TINY DM 2PX", module_px: 2) }, [2200, 250]],
        ["tiny_code128_x1_5px.png", "Code 128, X = 1.5 px (rendered at 3 px, box-downsampled 2x), 30 px tall",
          -> { zint("code_128", "TINY-C128-15", module_px: 3, height: 20).scaled(0.5) }, [1900, 3000]],
        ["tiny_code128_x2px.png", "Code 128, X = 2 px (6.7 mil), 40 px tall",
          -> { zint("code_128", "TINY-C128-20", module_px: 2, height: 20) }, [700, 3010]]
      ].each_with_index do |(file, what, build, (cx, cy)), i|
        scene = letter300("Tiny code fixture: #{File.basename(file, ".png")}", 300 + i)
        scene.place_centered(build.call, cx, cy)
        scene.output.pngsave(path(file), compression: 9, keep: :none)
        add(file, category: "tiny", kind: "png", effort: "fast", expected: scene.expected,
          notes: "US Letter at 300 dpi (2550x3300) with body text; #{what}. Found by the base pass; the page is " \
            "too large for the 2x high_res pass (longest side >= 2000 px).")
      end
      tiny_upscale
    end

    # A small, soft render: composed at 390 dpi with 6 px QR modules, blurred, downscaled to 100 dpi. The QR (EC level
    # L, version 5) ends up with 1.54 px modules and about half of its pixels mid-gray. Payload seed and placement
    # were picked so that zxing-cpp 3.1.1's base pass misses it (as it misses about a third of such renders) while
    # the bicubic upscale finds it, through libvips and ImageMagick alike and with ±1 noise added.
    def tiny_upscale
      scene = Scene.new(2184, 2262, dpi: 390)
      scene.text("Lorem ipsum dolor sit amet", 94, 70, pt: 11, font: "sans bold")
      scene.text(pseudo_text(Random.new(42), 70), 94, 203, pt: 8, width: 1996)
      rng = Random.new(4)
      text = +"zxing_ffi/tiny_qr_1_5px_upscale"
      text << " " << WORDS[rng.rand(WORDS.size)] while text.size < 96
      scene.place_centered(qr(text, module_px: 6, level: :l), 1094, 1561, tolerance: 6)
      scene.blur(2.4).resize(0.2564)
      file = "tiny_qr_1_5px_upscale.png"
      scene.output(dpi: 100).pngsave(path(file), compression: 9, keep: :none)
      add(file, category: "tiny", kind: "png", effort: "normal", requires: ["transformer"], expected: scene.expected,
        notes: "560x580 at 100 dpi, rendered soft (composed at 390 dpi, blurred, downscaled): QR, EC level L, " \
          "1.54 px modules. Missed by the base pass; found by the high_res pass, whose bicubic 2x upscale resolves " \
          "the modules (replicating pixels did not).")
    end

    # --- several codes per page -----------------------------------------------------------------------------------

    def multi
      scene = Scene.new(1275, 1650, dpi: 150)
      scene.text("Six symbologies on one page", 80, 60, pt: 18, font: "sans bold")
      [
        [qr("zxing_ffi/multi_6codes QR", module_px: 6), 330, 380, "QR Code"],
        [zint("data_matrix", "zxing_ffi/multi_6codes DM", module_px: 6), 945, 380, "Data Matrix"],
        [zint("code_128", "MULTI6-C128", module_px: 3, height: 30), 330, 830, "Code 128"],
        [zint("ean_13", "200000060160", module_px: 3, height: 50), 945, 830, "EAN-13"],
        [zint("pdf417", "zxing_ffi/multi_6codes PDF417", module_px: 3), 330, 1280, "PDF417"],
        [zint("aztec", "zxing_ffi/multi_6codes Aztec", module_px: 6), 945, 1280, "Aztec"]
      ].each do |code, x, y, caption|
        mark = scene.place_centered(code, x, y)
        scene.text(caption, x - 60, (mark.y + code.image.height / 2.0 + 10).round, pt: 10)
      end
      scene.output.pngsave(path("multi_6codes.png"), compression: 9, keep: :none)
      add("multi_6codes.png", category: "multi", kind: "png", effort: "fast", expected: scene.expected,
        notes: "Letter at 150 dpi: QR, Data Matrix, Code 128, EAN-13, PDF417 and Aztec, each once.")

      multi_identical_labels
      multi_qr_sheet
      multi_orientations
    end

    def shipping_label(number)
      label = Scene.new(560, 330, dpi: 150)
      label.draw do |m|
        m.draw_rect!(0, 0, 0, 560, 330, fill: false)
        m.draw_rect!(0, 1, 1, 558, 328, fill: false)
      end
      label.text("SHIP TO: Receiving Dock 4\n1 Example Way, Springfield", 20, 16, pt: 10)
      label.place_centered(qr("zxing_ffi/label/#{number}", module_px: 5), 110, 215)
      label.place_centered(zint("code_128", "LBL-#{number}", module_px: 2, height: 35), 395, 215)
      label
    end

    def multi_identical_labels
      scene = Scene.new(1275, 1650, dpi: 150)
      scene.text("Two copies of the same label", 80, 60, pt: 18, font: "sans bold")
      label = shipping_label("0001")
      scene.paste(label, 90, 200)
      scene.paste(label, 620, 1150)
      scene.output.pngsave(path("multi_identical_labels.png"), compression: 9, keep: :none)
      add("multi_identical_labels.png", category: "multi", kind: "png", effort: "fast", expected: scene.expected,
        notes: "Two identical labels (same QR text, same Code 128 text) far apart: 4 results. Identical content " \
          "at different positions is not a duplicate.")
    end

    def multi_qr_sheet
      scene = Scene.new(1275, 1650, dpi: 150)
      scene.text("Asset tag sheet (12 QR codes)", 80, 60, pt: 18, font: "sans bold")
      12.times do |i|
        x = 250 + (i % 3) * 388
        y = 320 + (i / 3) * 350
        number = format("%02d", i + 1)
        scene.place_centered(qr("zxing_ffi/asset/#{number}", module_px: 5), x, y)
        scene.text("ASSET #{number}", x - 50, y + 95, pt: 10)
      end
      scene.output.pngsave(path("multi_qr_sheet.png"), compression: 9, keep: :none)
      add("multi_qr_sheet.png", category: "multi", kind: "png", effort: "fast", expected: scene.expected,
        notes: "Letter at 150 dpi: 3x4 grid of distinct QR codes (5 px modules).")
    end

    def multi_orientations
      scene = Scene.new(1200, 1200, dpi: 150)
      [
        [qr("zxing_ffi/multi_orient QR", module_px: 6), 0, 30, 30],
        [zint("data_matrix", "zxing_ffi/multi_orient DM", module_px: 6), 1, 610, 30],
        [zint("code_128", "ORIENT-C128", module_px: 3, height: 30), 2, 30, 610],
        [zint("ean_13", "200000070009", module_px: 3, height: 50), 3, 610, 610]
      ].each do |code, turns, x, y|
        tile = Scene.new(560, 560, dpi: 150)
        tile.place_centered(code, 280, 280)
        tile.rot90(turns)
        scene.paste(tile, x, y)
      end
      scene.output.pngsave(path("multi_orientations.png"), compression: 9, keep: :none)
      add("multi_orientations.png", category: "multi", kind: "png", effort: "fast", expected: scene.expected,
        notes: "Four codes on one page at 0 (QR), 90 (Data Matrix), 180 (Code 128) and 270 (EAN-13) degrees.")
    end

    # --- degraded scans -------------------------------------------------------------------------------------------

    # 660x470 at 200 dpi: QR and Data Matrix (5 px modules) on the left, Code 128 (X 3 px) and text on the right.
    def degraded_scene(name, tag, paper: 255)
      scene = Scene.new(660, 470, dpi: 200, paper: paper)
      scene.text("Scanned document: #{name}", 20, 12, pt: 11)
      scene.place_centered(qr("zxing_ffi/degraded_#{name}", module_px: 5), 125, 165, blend: true)
      scene.place_centered(zint("data_matrix", "zxing_ffi/degraded_#{name}", module_px: 5), 125, 370, blend: true)
      scene.place_centered(zint("code_128", "DEG-#{tag}", module_px: 3, height: 30), 440, 165, blend: true)
      scene.text(pseudo_text(Random.new(name.sum), 30), 250, 275, pt: 8, width: 390)
      scene
    end

    def degraded
      [
        ["blur_mild", "B1", "png", "Gaussian blur sigma 1.2", "fast", ->(s) { s.blur(1.2) }],
        ["blur_heavy", "B2", "png", "Gaussian blur sigma 2.0 (3 px bars smear together)", "normal",
          ->(s) { s.blur(2.0) }],
        ["noise_mild", "N1", "png", "Gaussian noise sigma 20 (seed 101)", "fast", ->(s) { s.noise(20, seed: 101) }],
        ["noise_heavy", "N2", "png", "Gaussian noise sigma 45 (seed 102)", "normal", ->(s) { s.noise(45, seed: 102) }],
        ["jpeg_q30", "J30", "jpg", "JPEG q30", "fast", ->(s) { s }],
        ["jpeg_q12", "J12", "jpg", "slight blur (0.6) then JPEG q12 (blocking, ringing)", "fast", ->(s) { s.blur(0.6) }],
        ["threshold", "BW", "png", "blur 1.0 + noise 12 (seed 103), thresholded at 128 to a 1-bit PNG", "fast",
          ->(s) { s.blur(1.0).noise(12, seed: 103).threshold }],
        ["skew2", "S2", "png", "page skewed 2 degrees", "fast", ->(s) { s.rotate(2) }],
        ["skew5_g4", "S5", "tif", "page skewed 5 degrees, thresholded, CCITT G4 TIFF at 200 dpi", "fast",
          ->(s) { s.rotate(5).threshold }],
        ["faded", "FD", "png", "faded print: ink 115 on paper 170, noise 4 (seed 104)", "fast",
          ->(s) { s.tap { s.image = levels(s.image, 115, 170) }.noise(4, seed: 104) }]
      ].each do |name, tag, ext, what, effort, degrade|
        scene = degrade.call(degraded_scene(name, tag))
        file = "degraded_#{name}.#{ext}"
        image = scene.output
        case file
        when /q30/ then image.jpegsave(path(file), Q: 30, keep: :none)
        when /q12/ then image.jpegsave(path(file), Q: 12, keep: :none)
        when /threshold/ then image.pngsave(path(file), bitdepth: 1, compression: 9, keep: :none)
        when /g4/ then image.tiffsave(path(file), compression: :ccittfax4, bitdepth: 1, keep: :none, **tiff_res(200))
        else image.pngsave(path(file), compression: 9, keep: :none)
        end
        add(file, category: "degraded", kind: {"png" => "png", "jpg" => "jpeg", "tif" => "tiff"}.fetch(ext),
          effort: effort, expected: scene.expected,
          notes: "660x470 scan at 200 dpi (QR and Data Matrix 5 px modules, Code 128 X 3 px): #{what}.")
      end
      degraded_combo
    end

    # Gray paper, uneven light, skew, blur, noise and JPEG: an office scan of a slightly crooked page.
    def degraded_combo
      scene = degraded_scene("scan_combo", "SC", paper: 232)
      scene.rotate(3.5).blur(1.0)
      xyz = Vips::Image.xyz(scene.width, scene.height)
      light = xyz[0] * (-0.22 / scene.width) + xyz[1] * (-0.08 / scene.height) + 1.05
      scene.image = (scene.image * light).cast(:uchar)
      scene.noise(8, seed: 105)
      scene.output.jpegsave(path("degraded_scan_combo.jpg"), Q: 45, keep: :none)
      add("degraded_scan_combo.jpg", category: "degraded", kind: "jpeg", effort: "fast", expected: scene.expected,
        notes: "Gray paper (232), 3.5 deg skew, blur 1.0, left-to-right light falloff (~22%), noise 8 (seed 105), " \
          "JPEG q45.")
    end

    # --- false positives: no barcodes -----------------------------------------------------------------------------

    def fp(file, notes)
      add(file, category: "false_positive", kind: file.end_with?(".jpg") ? "jpeg" : "png", effort: "thorough",
        expected: [], notes: "#{notes} No barcodes: any result is a false positive (effort thorough = run every pass).")
    end

    def false_positive
      rng = Random.new(2026)
      scene = Scene.new(1275, 1650, dpi: 150)
      scene.text("Lorem ipsum dolor sit amet", 90, 60, pt: 16, font: "sans bold")
      [90, 665].each do |x|
        y = 140
        y += scene.text(pseudo_text(rng, 95), x, y, pt: 8, width: 520) + 18 while y < 1480
      end
      scene.output.pngsave(path("fp_dense_text.png"), compression: 9, keep: :none)
      fp("fp_dense_text.png", "Letter at 150 dpi, two columns of dense 8 pt text with numbers, dates and codes.")

      fp_table
      fp_rules_bars
      fp_random_bars
      fp_ledger
      fp_blank_scan
      fp_textures
    end

    def fp_table
      scene = Scene.new(1275, 1650, dpi: 150)
      scene.text("LOREM IPSUM 2026-0917", 90, 60, pt: 16, font: "sans bold")
      columns = [90, 190, 560, 680, 820, 980, 1185]
      scene.draw do |m|
        m.draw_rect!(215, 90, 150, 1095, 40, fill: true)
        (0..32).each { |r| m.draw_line!(0, 90, 150 + r * 40, 1185, 150 + r * 40) }
        columns.each { |x| m.draw_line!(0, x, 150, x, 1430) }
        m.draw_rect!(0, 88, 148, 1099, 1284, fill: false)
      end
      %w[Lorem Ipsum Dolor Sit Amet Elit].each_with_index do |head, i|
        scene.text(head, columns[i] + 8, 160, pt: 9, font: "sans bold")
      end
      rng = Random.new(917)
      (1..31).each do |r|
        y = 160 + r * 40
        cells = [format("%03d", r), "#{WORDS[rng.rand(WORDS.size)]} #{WORDS[rng.rand(WORDS.size)]}",
          rng.rand(1..999).to_s, format("%d.%02d", rng.rand(1..99), rng.rand(100)),
          format("%d.%02d", rng.rand(1..9999), rng.rand(100)), format("%d,%03d.%02d", rng.rand(1..99), rng.rand(1000),
            rng.rand(100))]
        cells.each_with_index { |cell, i| scene.text(cell, columns[i] + 8, y, pt: 9, font: "monospace") }
      end
      scene.output.pngsave(path("fp_table_grid.png"), compression: 9, keep: :none)
      fp("fp_table_grid.png", "Table: 1 px grid, shaded header, monospace numbers in every cell.")
    end

    def fp_rules_bars
      scene = Scene.new(1275, 1650, dpi: 150)
      scene.draw do |m|
        [120, 128, 300, 306, 312].each { |y| m.draw_rect!(0, 90, y, 1095, 2, fill: true) }
        m.draw_rect!(0, 90, 200, 1095, 5, fill: true)
        # a fence of regular bars and a ruler with ticks every 6 px (majors every 30 px)
        (0...70).each { |i| m.draw_rect!(0, 90 + i * 9, 380, 3, 70, fill: true) }
        (0..180).each { |i| m.draw_rect!(0, 90 + i * 6, 520, 1, (i % 5).zero? ? 40 : 18, fill: true) }
        # dashed and dotted rules
        (0...90).each { |i| m.draw_rect!(0, 90 + i * 12, 620, 7, 2, fill: true) }
        (0...180).each { |i| m.draw_rect!(0, 90 + i * 6, 660, 2, 2, fill: true) }
        # vertical column rules
        (0...12).each { |i| m.draw_rect!(0, 150 + i * 90, 1200, 2, 360, fill: true) }
      end
      [
        "||||||||||||||||||||||||||||||||||||||||||||||||||||||||",
        "| || ||| || | |||| | || ||| | || |||| || | ||| || | ||||",
        "IIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIII",
        "llllllllllllllllllllllllllllllllllllllllllllllllllllllllllll",
        "1111111111111111111111111111111111111111111111111111111111",
        "0000 1111 2222 3333 4444 5555 6666 7777 8888 9999 0000 1111",
        "=========================================================",
        "#########################################################"
      ].each_with_index do |line, i|
        scene.text(line, 90, 720 + i * 55, pt: 14, font: (i < 5) ? "sans" : "monospace")
      end
      scene.output.pngsave(path("fp_rules_bars.png"), compression: 9, keep: :none)
      fp("fp_rules_bars.png",
        "Rules, a fence of regular bars, a ruler with ticks, dashed/dotted lines, column rules and runs of " \
        "'|', 'I', 'l', '1' in text.")
    end

    def fp_random_bars
      scene = Scene.new(1275, 1650, dpi: 150)
      rng = Random.new(4242)
      scene.draw do |m|
        [[2, 70], [3, 90], [4, 120], [2, 50], [3, 160], [5, 100], [3, 60]].each_with_index do |(unit, height), row|
          x = 120
          y = 110 + row * 200
          while x < 1000
            bar = unit * rng.rand(1..4)
            m.draw_rect!(0, x, y, bar, height, fill: true)
            x += bar + unit * rng.rand(1..4)
          end
        end
      end
      # a real Code 128 with its right 40% papered over: a broken code must not decode
      code = zint("code_128", "BROKEN-128-CODE", module_px: 3, height: 30)
      scene.place_centered(code, 640, 1540)
      scene.marks.clear
      scene.draw { |m| m.draw_rect!(255, 640 + (code.width * 0.1).round, 1470, 400, 140, fill: true) }
      scene.output.pngsave(path("fp_random_bars.png"), compression: 9, keep: :none)
      fp("fp_random_bars.png",
        "Seven bands of pseudo-random bars/spaces (seed 4242; 1-4 units of 2-5 px) and a Code 128 whose right " \
        "part is covered.")
    end

    def fp_ledger
      scene = Scene.new(1275, 1650, dpi: 150)
      scene.text("LOREM IPSUM DOLOR", 90, 60, pt: 16, font: "monospace")
      rng = Random.new(1234)
      lines = Array.new(56) do |i|
        format("%s | %04d %04d %04d %04d | %9d.%02d | %-11s| %07d",
          format("2026-%02d-%02d", i / 28 + 8, i % 28 + 1), rng.rand(10_000), rng.rand(10_000), rng.rand(10_000),
          rng.rand(10_000), rng.rand(1_000_000), rng.rand(100), %w[LOREM IPSUM DOLOR AMET][rng.rand(4)],
          rng.rand(10_000_000))
      end
      scene.text(lines.join("\n"), 90, 140, pt: 9, font: "monospace")
      scene.output.pngsave(path("fp_ledger_numbers.png"), compression: 9, keep: :none)
      fp("fp_ledger_numbers.png", "Monospace columns: dates, 16-digit numbers, amounts, '|' separators.")
    end

    # A blank page through a scanner: off-white paper, a soft light gradient, faint noise, JPEG.
    def fp_blank_scan
      scene = Scene.new(1275, 1650, paper: 236, dpi: 150)
      xyz = Vips::Image.xyz(scene.width, scene.height)
      light = xyz[0] * (-0.06 / scene.width) + xyz[1] * (-0.04 / scene.height) + 1.02
      scene.image = (scene.image * light).cast(:uchar)
      scene.noise(3, seed: 99).blur(0.6)
      scene.output.jpegsave(path("fp_blank_scan.jpg"), Q: 75, keep: :none)
      fp("fp_blank_scan.jpg", "Blank letter page as scanned: paper 236, light gradient, noise 3 (seed 99), JPEG q75.")
    end

    def fp_textures
      scene = Scene.new(1200, 900, dpi: 150)
      xyz = Vips::Image.xyz(300, 300)
      checker = ->(size) { (((xyz[0] / size).floor + (xyz[1] / size).floor) % 2 * 255).cast(:uchar) }
      scene.image = scene.image.insert(checker.call(4), 0, 0).insert(checker.call(6), 300, 0)
        .insert(checker.call(10), 600, 0)
      dx = xyz[0] - 150
      dy = xyz[1] - 150
      rings = (((dx * dx + dy * dy)**0.5 / 8).floor % 2 * 255).cast(:uchar)
      scene.image = scene.image.insert(rings, 900, 0)
      # halftone dots whose size grows left to right, diagonal hatching, a random grid of 4 px black/white cells
      # (module-like, but without finder patterns) and blurred film grain
      dots = Vips::Image.black(600, 300).new_from_image(255).cast(:uchar).mutate do |m|
        (0...50).each do |i|
          (0...25).each { |j| m.draw_circle!(0, 6 + i * 12, 6 + j * 12, 1 + i / 10, fill: true) }
        end
      end
      scene.image = scene.image.insert(dots, 0, 300)
      hatch = ((xyz[0] + xyz[1]) % 9 < 3).ifthenelse(0, 255).cast(:uchar)
      scene.image = scene.image.insert(hatch, 600, 300).insert(hatch.flip(:horizontal), 900, 300)
      cells = Vips::Image.new_from_memory_copy(Random.new(77).bytes(150 * 75), 150, 75, 1, :uchar)
      cells = (cells > 127).ifthenelse(0, 255).cast(:uchar).zoom(4, 4)
      grain = Vips::Image.new_from_memory_copy(Random.new(78).bytes(600 * 300), 600, 300, 1, :uchar).gaussblur(1.5)
      scene.image = scene.image.insert(cells, 0, 600).insert(grain, 600, 600)
      scene.output.pngsave(path("fp_textures.png"), compression: 9, keep: :none)
      fp("fp_textures.png",
        "Checkerboards (4/6/10 px), concentric rings, halftone dots, hatching, a random grid of 4 px cells (seed 77) " \
        "and blurred grain (seed 78).")
    end

    # --- limits: headers declaring more than max_pixels (64 MP) ---------------------------------------------------

    def limits
      notes = "must raise LimitExceeded from header metadata, before decoding."

      raw = ("\x00".b + ("\xFF".b * 50_000)) * 4
      File.binwrite(path("limits_png_50000x50000.png"), png_bytes(50_000, 50_000, bit_depth: 8, color_type: 0,
        idat: Zlib::Deflate.deflate(raw)))
      limit("limits_png_50000x50000.png", "png", "PNG, IHDR 50000x50000 gray (2.5 GP), IDAT holds 4 rows: #{notes}")

      row = "\x00".b + ("\xFF".b * 1125)
      File.binwrite(path("limits_png_bomb_9000x9000.png"), png_bytes(9000, 9000, bit_depth: 1, color_type: 0,
        idat: Zlib::Deflate.deflate(row * 9000, Zlib::BEST_COMPRESSION)))
      limit("limits_png_bomb_9000x9000.png", "png",
        "Valid, complete 1-bit white PNG of 9000x9000 (81 MP) in a few KB (decompression bomb): #{notes}")

      File.binwrite(path("limits_jpeg_60000x60000.jpg"), huge_jpeg(60_000, 60_000))
      limit("limits_jpeg_60000x60000.jpg", "jpeg", "JPEG whose SOF0 says 60000x60000; one MCU of data: #{notes}")

      File.binwrite(path("limits_gif_30000x30000.gif"), huge_gif(30_000, 30_000))
      limit("limits_gif_30000x30000.gif", "gif", "GIF, screen and frame 30000x30000, LZW data for 1 pixel: #{notes}")

      File.binwrite(path("limits_tiff_100000x100000.tif"), huge_tiff(100_000, 100_000))
      limit("limits_tiff_100000x100000.tif", "tiff",
        "TIFF IFD says 100000x100000 8-bit gray; one deflate strip holding a single row: #{notes}")

      # ImageMagick's `identify` refuses small files that declare huge BMP/PNM dimensions ("insufficient image
      # data in file"), so the scanner reads these headers itself (ZXingFFI::HeaderProbe) before any loader runs.
      im_note = "ImageMagick's identify fails on this file ('insufficient image data'); the scanner's header probe " \
        "rejects it before any loader runs."
      File.binwrite(path("limits_bmp_30000x30000.bmp"), huge_bmp(30_000, 30_000))
      limit("limits_bmp_30000x30000.bmp", "bmp",
        "BMP header says 30000x30000 24-bit, 16 bytes of pixels: #{notes} #{im_note}")

      File.binwrite(path("limits_webp_16383x16383.webp"), huge_webp(16_383, 16_383))
      limit("limits_webp_16383x16383.webp", "webp", "Lossless WebP (VP8L) header 16383x16383, truncated: #{notes}")

      File.binwrite(path("limits_pgm_50000x50000.pgm"), "P5\n50000 50000\n255\n" + ("\xFF".b * 64))
      limit("limits_pgm_50000x50000.pgm", "pnm",
        "P5 header 50000x50000, 64 bytes of samples: #{notes} The pure-Ruby PNM loader raises LimitExceeded; " \
        "#{im_note}")
    end

    def limit(file, kind, notes)
      add(file, category: "limits", kind: kind, effort: "fast", expect_error: "LimitExceeded", expected: [],
        notes: "#{notes} (default max_pixels 64,000,000).")
    end

    # A real 16x16 JPEG from libvips with the SOF0 dimensions patched.
    def huge_jpeg(width, height)
      data = Vips::Image.black(16, 16).new_from_image(255).cast(:uchar).jpegsave_buffer(Q: 75, keep: :none).b
      sof = data.index("\xFF\xC0".b) or raise "no SOF0"
      data[sof + 5, 4] = [height, width].pack("nn")
      data
    end

    def huge_gif(width, height)
      screen = [width, height].pack("v2") + [0x80, 0, 0].pack("C3") + [0, 0, 0, 255, 255, 255].pack("C*")
      # LZW, minimum code size 2: clear (4), pixel 0, end of information (5) as 3-bit codes, LSB first.
      frame = "\x2C".b + [0, 0, width, height].pack("v4") + "\x00\x02\x02\x44\x01\x00".b
      "GIF89a".b + screen + frame + "\x3B".b
    end

    # One deflate strip holding a single row. (Compressed, so libtiff cannot flag the byte count as bogus while
    # reading the header; an uncompressed truncated strip makes libvips print a warning.)
    def huge_tiff(width, height)
      strip = Zlib::Deflate.deflate("\xFF".b * width)
      entries = [
        [256, 4, width], [257, 4, height], [258, 3, 8], [259, 3, 8], [262, 3, 1], [273, 4, 8 + 2 + 10 * 12 + 4],
        [277, 3, 1], [278, 4, height], [279, 4, strip.bytesize], [284, 3, 1]
      ]
      ifd = [entries.size].pack("v") + entries.map { |tag, type, value|
        [tag, type, 1].pack("vvV") + ((type == 3) ? [value, 0].pack("vv") : [value].pack("V"))
      }.join + [0].pack("V")
      "II*\x00".b + [8].pack("V") + ifd + strip
    end

    def huge_bmp(width, height)
      header = ["BM", 54 + 16, 0, 0, 54].pack("a2Vv2V")
      info = [40, width, height, 1, 24, 0, 0, 2835, 2835, 0, 0].pack("Vl<l<vvVVl<l<VV")
      header + info + ("\xFF".b * 16)
    end

    def huge_webp(width, height)
      bits = (width - 1) | ((height - 1) << 14)
      vp8l = "\x2F".b + [bits].pack("V") + ("\x00".b * 8)
      chunk = "VP8L".b + [vp8l.bytesize].pack("V") + vp8l + (vp8l.bytesize.odd? ? "\x00".b : "".b)
      "RIFF".b + [4 + chunk.bytesize].pack("V") + "WEBP".b + chunk
    end

    # --- output ---------------------------------------------------------------------------------------------------

    def write_fragment
      header = <<~YAML
        # GENERATED by script/fixtures/images.rb (raster corpus); edit the generator, not this file.
        # Schema: test/fixtures/README.md. Centers are in displayed pixels (after orientation/aspect correction).
      YAML
      FileUtils.mkdir_p(File.dirname(FRAGMENT))
      File.write(FRAGMENT, header + YAML.dump(@entries))
    end

    def report
      files = Dir[File.join(OUT, "*")].sort
      total = files.sum { |f| File.size(f) }
      largest = files.max_by { |f| File.size(f) }
      puts "Wrote #{files.size} files (#{(total / 1024.0 / 1024).round(2)} MiB) to #{OUT}; largest " \
        "#{File.basename(largest)} (#{File.size(largest) / 1024} KiB)"
      puts "Wrote #{FRAGMENT} (#{@entries.size} entries)"
    end
  end
end

ImageFixtures::Generator.new.run if $PROGRAM_NAME == __FILE__
