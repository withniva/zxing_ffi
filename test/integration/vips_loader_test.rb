# frozen_string_literal: true

require "test_helper"

# The normalization contract and VipsLoader, with inputs written by libvips from an rqrcode-encoded QR.
class VipsLoaderTest < Minitest::Test
  IMAGES = ZXingFFI::SyntheticImages
  LOADER = ZXingFFI::Loaders::VipsLoader

  def setup
    require_tool!(:vips) { LOADER.available? }
    require_native!
    @dir = Dir.mktmpdir("zxing_vips")
  end

  def teardown
    FileUtils.rm_rf(@dir) if @dir
    super
  end

  # The synthetic QR as a libvips image (uchar, 1 band).
  def qr_vips(**options)
    pixels, width, height = IMAGES.render(**options)
    ::Vips::Image.new_from_memory_copy(pixels, width, height, 1, :uchar).copy(interpretation: :"b-w")
  end

  def write(name)
    path = File.join(@dir, name)
    yield path
    path
  end

  def load(path, config: ZXingFFI::Config.new, page: 1)
    ZXingFFI::Source.open(path) do |source|
      document = LOADER.new(config).open(source)
      begin
        yield document.render(page), document
      ensure
        document.close
      end
    end
  end

  def assert_decodes(image, text = IMAGES::QR_TEXT)
    assert_equal :lum, image.format
    assert_equal [text], ZXingFFI.read(image).map(&:text)
  end

  def test_capabilities
    assert LOADER.supports?(:png)
    assert LOADER.supports?(:jpeg)
    assert LOADER.supports?(:tiff)
    refute LOADER.supports?(:pdf), "pdfload is untrusted: refused while vips_block_untrusted is true"
    refute LOADER.supports?(:pnm), "ppmload is untrusted"
    refute LOADER.supports?(:unknown)
    diag = LOADER.diagnostics
    assert diag[:available]
    assert_match(/\A8\./, diag[:version])
    assert_includes diag[:untrusted_operations], "pdfload"
  end

  def test_untrusted_operations_can_be_opted_into
    ZXingFFI.config.vips_block_untrusted = false
    assert LOADER.supports?(:pdf)
    assert LOADER.supports?(:pnm)
  end

  def test_gray_png
    path = write("qr.png") { |p| qr_vips.pngsave(p) }
    load(path) do |page, document|
      assert_decodes page.image
      assert_equal 1, document.page_count
      assert_nil page.dpi
      assert_equal :vips, page.metadata[:loader]
      assert_nil page.metadata[:orientation_applied]
      assert_nil page.metadata[:aspect_corrected]
      info = document.page_info(1)
      assert_equal [page.image.width, page.image.height, :px], [info.width, info.height, info.unit]
    end
  end

  def test_rgb_jpeg_and_webp_and_gif
    rgb = qr_vips.bandjoin([qr_vips, qr_vips]).copy(interpretation: :srgb)
    {"qr.jpg" => ->(p) { rgb.jpegsave(p, Q: 92) }, "qr.webp" => ->(p) { rgb.webpsave(p, lossless: true) },
     "qr.gif" => ->(p) { rgb.gifsave(p) }}.each do |name, saver|
      path = write(name) { |p| saver.call(p) }
      load(path) { |page| assert_decodes page.image }
    end
  end

  def test_sixteen_bit_png_is_scaled_not_truncated
    ramp = ::Vips::Image.new_from_array([[0, 257, 32_768, 65_535]]).cast(:ushort).copy(interpretation: :grey16)
    path = write("ramp16.png") { |p| ramp.pngsave(p) }
    load(path) { |page| assert_equal [0, 1, 128, 255], page.image.to_bytes.bytes }

    qr16 = (qr_vips.cast(:ushort) * 257).cast(:ushort).copy(interpretation: :grey16)
    load(write("qr16.png") { |p| qr16.pngsave(p) }) { |page| assert_decodes page.image }
  end

  def test_transparent_pixels_stored_as_black_become_white
    qr = qr_vips
    # dark modules opaque black; background fully transparent *black* (RGB 0, alpha 0)
    alpha = (qr < 128).ifthenelse(255, 0).cast(:uchar)
    black = ::Vips::Image.black(qr.width, qr.height).cast(:uchar)
    rgba = black.bandjoin([black, black, alpha]).copy(interpretation: :srgb)
    path = write("alpha.png") { |p| rgba.pngsave(p) }
    load(path) do |page|
      corner = page.image.to_bytes.getbyte(0)
      assert_equal 255, corner, "transparent background must be flattened onto white"
      assert_decodes page.image
    end

    gray_alpha = black.bandjoin(alpha).copy(interpretation: :"b-w")
    load(write("gray_alpha.png") { |p| gray_alpha.pngsave(p) }) { |page| assert_decodes page.image }
  end

  def test_cmyk_jpeg
    path = File.join(@dir, "cmyk.jpg")
    qr_vips.pngsave(File.join(@dir, "src.png"))
    skip "magick needed to write a CMYK JPEG" unless ZXingFFI::TestSupport.which("magick")
    system("magick", File.join(@dir, "src.png"), "-colorspace", "CMYK", path, exception: true)
    load(path) { |page| assert_decodes page.image }
  end

  def test_palette_png
    rgb = qr_vips.bandjoin([qr_vips, qr_vips]).copy(interpretation: :srgb)
    path = write("palette.png") { |p| rgb.pngsave(p, palette: true) }
    load(path) { |page| assert_decodes page.image }
  end

  def test_one_bit_tiff_becomes_0_and_255
    path = write("bw.tif") { |p| qr_vips.tiffsave(p, bitdepth: 1) }
    load(path) do |page|
      assert_equal [0, 255], page.image.to_bytes.bytes.uniq.sort
      assert_decodes page.image
    end
  end

  def test_multi_page_tiff
    pages = [qr_vips, ::Vips::Image.black(116, 116).invert.cast(:uchar), qr_vips(invert: true)]
    joined = ::Vips::Image.arrayjoin(pages, across: 1).copy(interpretation: :"b-w")
    joined = joined.mutate { |m| m.set_type!(GObject::GINT_TYPE, "page-height", 116) }
    path = write("multi.tif") { |p| joined.tiffsave(p) }

    ZXingFFI::Source.open(path) do |source|
      document = LOADER.new.open(source)
      assert_equal 3, document.page_count
      assert_decodes document.render(1).image
      assert_empty ZXingFFI.read(document.render(2).image)
      assert_equal 1, ZXingFFI.read(document.render(3).image).size
      assert_raises(ArgumentError) { document.render(4) }
    end
  end

  def test_exif_orientation_is_applied
    upright = qr_vips(canvas: [300, 150], offset: [10, 10])
    expected = ZXingFFI.read(ZXingFFI::Image.new(upright.write_to_memory, width: 300, height: 150)).first
    {6 => :d270, 3 => :d180, 8 => :d90}.each do |orientation, stored_rotation|
      stored = upright.rot(stored_rotation).mutate { |m| m.set_type!(GObject::GINT_TYPE, "orientation", orientation) }
      path = write("exif#{orientation}.jpg") { |p| stored.jpegsave(p, Q: 95) }
      load(path) do |page, document|
        assert_equal [300, 150], [page.image.width, page.image.height], "orientation #{orientation} displayed upright"
        assert_equal orientation, page.metadata[:orientation_applied]
        barcode = ZXingFFI.read(page.image).first
        assert_in_delta expected.center.x, barcode.center.x, 3
        assert_in_delta expected.center.y, barcode.center.y, 3
        info = document.page_info(1)
        assert_equal [300, 150], [info.width, info.height]
      end
    end
  end

  def test_fax_aspect_ratio_is_corrected
    square = qr_vips(scale: 4)
    squashed = square.resize(1.0, vscale: 98.0 / 204, kernel: :nearest).copy(xres: 204 / 25.4, yres: 98 / 25.4)
    path = write("fax.tif") { |p| squashed.tiffsave(p, compression: :ccittfax4, bitdepth: 1) }
    load(path) do |page, document|
      assert_in_delta square.height, page.image.height, 2
      assert_equal square.width, page.image.width
      assert_equal [204.0, 98.0], page.metadata[:aspect_corrected]
      assert_decodes page.image
      assert_equal 204.0, document.page_info(1).native_ppi
    end
  end

  def test_small_resolution_differences_are_left_alone
    image = qr_vips.copy(xres: 300 / 25.4, yres: 290 / 25.4)
    load(write("near.tif") { |p| image.tiffsave(p) }) { |page| assert_nil page.metadata[:aspect_corrected] }
  end

  def test_max_pixels_is_checked_before_decoding
    path = write("qr.png") { |p| qr_vips.pngsave(p) }
    error = assert_raises(ZXingFFI::LimitExceeded) { load(path, config: ZXingFFI::Config.new.with(max_pixels: 1_000)) { flunk } }
    assert_equal :max_pixels, error.limit
    assert_equal 116 * 116, error.value
  end

  # A 600x400 page (240,000 pixels) with the QR at 6 px modules; returns the path and the code found at full size.
  def oversized(name, &save)
    image = qr_vips(scale: 6, canvas: [600, 400], offset: [150, 30])
    path = write(name) { |p| save.call(image, p) }
    [path, ZXingFFI.scan(path).first]
  end

  # scan_pages with +options+; returns the page and the size of the image the passes decoded.
  def scan_downscaled(path, **options)
    loaded = nil
    page = ZXingFFI.scan_pages(path, oversize: :downscale, **options, instrument: ->(event, payload) {
      loaded = [payload[:width], payload[:height]] if event == :page_loaded
    }).first
    [page, loaded]
  end

  def test_oversize_raises_by_default
    path, = oversized("qr.png") { |image, p| image.pngsave(p) }
    error = assert_raises(ZXingFFI::LimitExceeded) { ZXingFFI.scan(path, max_pixels: 100_000) }
    assert_equal :max_pixels, error.limit
  end

  def test_oversize_downscale_decodes_smaller_and_reports_in_the_originals_pixels
    {"qr.png" => ->(image, p) { image.pngsave(p) }, "qr.tif" => ->(image, p) { image.tiffsave(p) },
     "qr.webp" => ->(image, p) { image.webpsave(p, lossless: true) }}.each do |name, save|
      path, full = oversized(name, &save)
      page, loaded = scan_downscaled(path, max_pixels: 100_000)

      assert_operator loaded.inject(:*), :<=, 100_000, name
      assert_in_delta Math.sqrt(100_000 / 240_000.0), page.metadata[:downscaled][:scale], 0.01, name
      assert_equal [600, 400], page.metadata[:downscaled][:from], name
      assert_equal [600, 400], [page.width, page.height], name
      barcode = page.barcodes.first
      assert_equal IMAGES::QR_TEXT, barcode.text, name
      assert_in_delta full.center.x, barcode.center.x, 3, "#{name}: x in the original's pixels"
      assert_in_delta full.center.y, barcode.center.y, 3, "#{name}: y in the original's pixels"
    end
  end

  def test_oversize_downscale_shrinks_jpeg_while_decoding_and_applies_exif_orientation
    upright = qr_vips(scale: 6, canvas: [600, 400], offset: [150, 30])
    full = ZXingFFI.read(ZXingFFI::Image.new(upright.write_to_memory, width: 600, height: 400)).first
    stored = upright.rot(:d270).mutate { |m| m.set_type!(GObject::GINT_TYPE, "orientation", 6) }
    path = write("exif6.jpg") { |p| stored.jpegsave(p, Q: 95) }
    page, loaded = scan_downscaled(path, max_pixels: 50_000) # scale 0.46: the JPEG decodes at 1/2, then resizes

    assert_operator loaded.inject(:*), :<=, 50_000
    assert_operator loaded[0], :>, loaded[1], "displayed upright"
    assert_equal [600, 400], [page.width, page.height]
    assert_equal 6, page.metadata[:orientation_applied]
    barcode = page.barcodes.first
    assert_equal IMAGES::QR_TEXT, barcode.text
    assert_in_delta full.center.x, barcode.center.x, 4
    assert_in_delta full.center.y, barcode.center.y, 4
  end

  def test_oversize_downscale_flattens_alpha_before_resampling
    path = fixture_path("images", "alpha_rgba_black_transparent.png")
    width, height = ZXingFFI.scan_pages(path).first.then { |page| [page.width, page.height] }
    page, = scan_downscaled(path, max_pixels: (width * height * 0.6).floor)
    assert page.metadata[:downscaled]
    refute_empty page.barcodes, "transparent black must become white before the resize"
  end

  def test_max_source_pixels_still_raises_when_downscaling
    %w[qr.png qr.tif].each do |name| # PNG: the scanner's header check; TIFF: the loader
      path, = oversized(name) { |image, p| image.write_to_file(p) }
      error = assert_raises(ZXingFFI::LimitExceeded, name) do
        ZXingFFI.scan(path, oversize: :downscale, max_pixels: 100_000, max_source_pixels: 200_000)
      end
      assert_equal [:max_source_pixels, 240_000], [error.limit, error.value], name
    end
  end

  def test_a_valid_png_bomb_is_streamed_down_when_downscaling
    page, loaded = scan_downscaled(fixture_path("images", "limits_png_bomb_9000x9000.png"))
    assert_operator loaded.inject(:*), :<=, 64_000_000
    assert_equal [9000, 9000], [page.width, page.height]
    assert_empty page.barcodes
  end

  def test_corrupt_file_raises_render_error
    path = write("broken.png") { |p| File.binwrite(p, "\x89PNG\r\n\x1a\n".b + ("\x00" * 64)) }
    assert_raises(ZXingFFI::RenderError, ZXingFFI::UnsupportedInput) { load(path) { flunk } }
  end

  # libvips' error buffer is process-wide and successful calls can leave warnings in it (Ubuntu's heifload leaves
  # "bad seek" after a good AVIF load); the next failure's message used to show those stale lines instead of its
  # own cause (found by the Docker CI run).
  def test_render_errors_report_their_own_cause_not_stale_libvips_messages
    ::Vips.attach_function(:vips_error, [:string, :string, :varargs], :void) unless ::Vips.respond_to?(:vips_error)
    path = write("broken.png") { |p| File.binwrite(p, "\x89PNG\r\n\x1a\n".b + ("\x00" * 64)) }
    3.times { |i| ::Vips.vips_error("stale", "%s", :string, "left over from an earlier call #{i}") }

    error = assert_raises(ZXingFFI::RenderError) { load(path) { flunk } }
    refute_match(/left over/, error.message)
    refute_match(/left over/, error.stderr)
    assert_match(/broken\.png/, error.message)
  ensure
    ::Vips.vips_error_clear
  end

  def test_heif_when_supported
    skip "libvips without heifsave" unless ::Vips.type_find("VipsOperation", "heifsave") != 0 && LOADER.supports?(:heif)

    path = write("qr.heic") { |p| qr_vips(scale: 6).bandjoin([qr_vips(scale: 6), qr_vips(scale: 6)]).copy(interpretation: :srgb).heifsave(p, Q: 95, compression: :hevc) }
    assert_equal :heif, ZXingFFI::Sniffer.sniff(path)
    load(path) { |page| assert_decodes page.image }
  rescue ::Vips::Error => e
    skip "cannot write HEIC here: #{e.message.lines.first}"
  end

  def test_pdf_when_opted_in
    ZXingFFI.config.vips_block_untrusted = false
    pdf = fixture_path("pdfs", "multipage_codes_p1_p3.pdf")
    skip "PDF fixtures not generated" unless File.exist?(pdf)

    ZXingFFI::Source.open(pdf) do |source|
      document = LOADER.new(ZXingFFI.config).open(source)
      assert_equal 3, document.page_count
      info = document.page_info(1)
      assert_equal [612, 792, :pt], [info.width, info.height, info.unit]
      page = document.render(1, dpi: 144)
      assert_equal [1224, 1584], [page.image.width, page.image.height]
      assert_equal 144, page.dpi
      refute_empty ZXingFFI.read(page.image)
    end
  end

  def test_pdf_rotate_is_applied
    ZXingFFI.config.vips_block_untrusted = false
    pdf = fixture_path("pdfs", "rotate90_page.pdf")
    skip "PDF fixtures not generated" unless File.exist?(pdf)

    ZXingFFI::Source.open(pdf) do |source|
      info = LOADER.new(ZXingFFI.config).open(source).page_info(1)
      assert_equal [792, 612], [info.width, info.height], "/Rotate 90: the page as displayed is landscape"
    end
  end

  def test_encrypted_pdf
    ZXingFFI.config.vips_block_untrusted = false
    pdf = fixture_path("pdfs", "encrypted_aes256_user_password.pdf")
    skip "PDF fixtures not generated" unless File.exist?(pdf)

    ZXingFFI::Source.open(pdf) do |source|
      assert_raises(ZXingFFI::PasswordRequired) { LOADER.new(ZXingFFI.config).open(source) }
      error = assert_raises(ZXingFFI::IncorrectPassword) { LOADER.new(ZXingFFI.config).open(source, password: "nope") }
      assert_kind_of ZXingFFI::PasswordRequired, error
      assert_equal 1, LOADER.new(ZXingFFI.config).open(source, password: "secret").page_count
    end
  end

  def test_concurrent_renders
    joined = ::Vips::Image.arrayjoin([qr_vips] * 4, across: 1).copy(interpretation: :"b-w")
    joined = joined.mutate { |m| m.set_type!(GObject::GINT_TYPE, "page-height", 116) }
    path = write("four.tif") { |p| joined.tiffsave(p) }
    ZXingFFI::Source.open(path) do |source|
      document = LOADER.new.open(source)
      texts = Array.new(4) { |i| Thread.new { ZXingFFI.read(document.render(i + 1).image).map(&:text) } }.map(&:value)
      assert_equal [[IMAGES::QR_TEXT]] * 4, texts
    end
  end

  # libvips caches loads by file name: a file overwritten at the same path must not decode as its old contents
  # (found by the raster fixture agent; e.g. an upload handler reusing a temp path).
  def test_overwritten_file_is_not_served_from_the_libvips_cache
    path = write("upload.png") { |p| qr_vips.pngsave(p) }
    assert_equal [IMAGES::QR_TEXT], ZXingFFI.scan(path, loader: :vips).map(&:text)

    other = ZXingFFI::Image.from_pgm(fixture_bytes("symbologies", "qr_code.pgm"))
    ::Vips::Image.new_from_memory_copy(other.to_bytes, other.width, other.height, 1, :uchar).pngsave(path)
    assert_equal ["Hello, World!"], ZXingFFI.scan(path, loader: :vips).map(&:text)
  end

  def test_buffer_fallback_for_libvips_without_revalidate
    path = write("fallback.png") { |p| qr_vips.pngsave(p) }
    original = ::Vips.method(:at_least_libvips?)
    ::Vips.define_singleton_method(:at_least_libvips?) { |major, minor| (major == 8 && minor == 15) ? false : original.call(major, minor) }

    assert_equal [IMAGES::QR_TEXT], ZXingFFI.scan(path, loader: :vips).map(&:text)
  ensure
    ::Vips.define_singleton_method(:at_least_libvips?, original) if original
  end

  def test_scan_through_the_registry
    path = write("qr.png") { |p| qr_vips.pngsave(p) }
    barcodes = ZXingFFI.scan(path, loader: :vips)

    assert_equal [IMAGES::QR_TEXT], barcodes.map(&:text)
    assert_equal [1], barcodes.map(&:page)
  end
end
