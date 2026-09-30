# frozen_string_literal: true

require "test_helper"
require_relative "../support/fake_transformer"

# ImageMagickLoader and ImageMagickTransformer. Inputs are written by ImageMagick from the
# rqrcode-encoded synthetic QR (so the barcode encoder stays independent of zxing-cpp).
class ImageMagickTest < Minitest::Test
  IMAGES = ZXingFFI::SyntheticImages
  LOADER = ZXingFFI::Loaders::ImageMagickLoader

  def setup
    require_tool!(:image_magick) { LOADER.available? }
    require_native!
    @dir = Dir.mktmpdir("zxing_im")
    @source_pgm = File.join(@dir, "qr.pgm")
    File.binwrite(@source_pgm, IMAGES.qr_image.to_pgm)
    @magick = ZXingFFI::ImageMagick.tool.convert
  end

  def teardown
    FileUtils.rm_rf(@dir) if @dir
    super
  end

  def convert(name, *args, input: @source_pgm)
    path = File.join(@dir, name)
    system(*@magick, input, *args, path, exception: true)
    path
  end

  def load(path, config: ZXingFFI::Config.new, page: 1)
    ZXingFFI::Source.open(path) do |source|
      document = LOADER.new(config).open(source)
      yield document.render(page), document
    end
  end

  def assert_decodes(image)
    assert_equal :lum, image.format
    assert_equal [IMAGES::QR_TEXT], ZXingFFI.read(image).map(&:text)
  end

  def test_detects_imagemagick
    tool = ZXingFFI::ImageMagick.tool
    assert_includes %i[im7 im6], tool.flavor
    assert_match(/\A\d+\.\d+\.\d+/, tool.version)
    assert_equal tool.version, LOADER.diagnostics[:version]
    refute_includes LOADER.kinds, :pdf, "ImageMagick must never read PDF"
  end

  def test_unusable_configured_magick
    ZXingFFI.config.tool_paths[:magick] = "/nonexistent/magick"
    LOADER.reset!
    refute LOADER.available?
    assert_match(/nonexistent/, LOADER.unavailable_reason)
  ensure
    ZXingFFI.reset_config!
    LOADER.reset!
  end

  def test_common_formats
    {"qr.png" => [], "qr.jpg" => ["-quality", "92"], "qr.gif" => [], "qr.bmp" => [], "qr.webp" => ["-define", "webp:lossless=true"],
     "qr.tif" => []}.each do |name, args|
      path = convert(name, *args)
      load(path) { |page| assert_decodes page.image }
    end
    load(@source_pgm) { |page| assert_decodes page.image }
  end

  def test_scan_via_the_registry
    path = convert("qr.bmp")
    assert_equal [IMAGES::QR_TEXT], ZXingFFI.scan(path, loader: :image_magick).map(&:text)
  end

  def test_coder_prefix_prevents_format_redetection
    # PNG magic followed by garbage: must fail as PNG instead of being re-detected as something else.
    path = File.join(@dir, "fake.png")
    File.binwrite(path, "\x89PNG\r\n\x1a\n".b + "push graphic-context\nviewbox 0 0 10 10\n")
    assert_raises(ZXingFFI::RenderError) { load(path) { flunk } }
  end

  def test_never_opens_pdf
    in_tmpdir do |dir|
      path = File.join(dir, "doc.pdf")
      File.binwrite(path, "%PDF-1.7\n%%EOF\n")
      ZXingFFI::Source.open(path) do |source|
        assert_raises(ZXingFFI::UnsupportedInput) { LOADER.new.open(source) }
      end
    end
  end

  def test_exif_orientation
    upright = convert("upright.png", "-gravity", "northwest", "-background", "white", "-extent", "300x150")
    expected = ZXingFFI.read(ZXingFFI::Image.from_pgm(File.binread(convert("upright.pgm", input: upright)))).first
    # ImageMagick's -orient does not create an EXIF block for a JPEG without one, so write the tag with libvips.
    skip "writing an EXIF orientation needs ruby-vips" unless ZXingFFI::Loaders::VipsLoader.available?
    stored = File.join(@dir, "stored.jpg")
    rotated = convert("rotated.png", "-rotate", "-90", input: upright)
    ::Vips::Image.new_from_file(rotated).mutate { |m| m.set_type!(GObject::GINT_TYPE, "orientation", 6) }.jpegsave(stored, Q: 95)
    load(stored) do |page|
      assert_equal [300, 150], [page.image.width, page.image.height]
      barcode = ZXingFFI.read(page.image).first
      assert_in_delta expected.center.x, barcode.center.x, 3
      assert_in_delta expected.center.y, barcode.center.y, 3
    end
  end

  def test_transparent_black_background_becomes_white
    path = convert("alpha.png", "-alpha", "copy", "-channel", "A", "-negate", "+channel", "-fill", "black", "-colorize", "100")
    load(path) do |page|
      assert_equal 255, page.image.to_bytes.getbyte(0)
      assert_decodes page.image
    end
  end

  def test_sixteen_bit_png_is_scaled
    path = File.join(@dir, "ramp16.png")
    system(*@magick, "-size", "4x1", "xc:black", "-depth", "16",
      "-fill", "gray(0.3922%)", "-draw", "point 1,0", "-fill", "gray(50.0008%)", "-draw", "point 2,0",
      "-fill", "white", "-draw", "point 3,0", path, exception: true)
    load(path) do |page|
      values = page.image.to_bytes.bytes
      assert_equal 0, values[0]
      assert_in_delta 1, values[1], 1
      assert_in_delta 128, values[2], 1
      assert_equal 255, values[3]
    end
  end

  def test_fax_aspect_correction
    path = convert("fax.tif", "-sample", "100%x48.04%!", "-units", "PixelsPerInch", "-density", "204x98",
      "-monochrome", "-compress", "Group4")
    load(path) do |page, document|
      assert_in_delta 116, page.image.height, 2
      assert_equal 116, page.image.width
      assert_equal [204.0, 98.0], page.metadata[:aspect_corrected]
      assert_decodes page.image
      assert_in_delta 116, document.page_info(1).height, 2
    end
  end

  def test_multi_page_tiff
    blank = convert("blank.png", "-fill", "white", "-colorize", "100")
    path = File.join(@dir, "multi.tif")
    system(*@magick, @source_pgm, blank, @source_pgm, path, exception: true)
    ZXingFFI::Source.open(path) do |source|
      document = LOADER.new.open(source)
      assert_equal 3, document.page_count
      assert_decodes document.render(1).image
      assert_empty ZXingFFI.read(document.render(2).image)
      assert_decodes document.render(3).image
    end
  end

  def test_paths_with_imagemagick_special_characters
    special = File.join(@dir, "we[0]ird *name?@%.png")
    FileUtils.cp(convert("plain.png"), special)
    assert_equal [IMAGES::QR_TEXT], ZXingFFI.scan(special, loader: :image_magick).map(&:text)
  end

  def test_max_pixels_checked_from_identify
    path = convert("qr2.png")
    error = assert_raises(ZXingFFI::LimitExceeded) { load(path, config: ZXingFFI::Config.new.with(max_pixels: 100)) { flunk } }
    assert_equal 116 * 116, error.value
  end

  def test_transformer_resize_and_quarter_turns
    transformer = ZXingFFI::Transformers::ImageMagickTransformer.new
    reference = ZXingFFI::FakeTransformer.new
    image = IMAGES.qr_image(canvas: [150, 120], offset: [10, 0])

    assert_equal reference.resize(image, 2).to_bytes, transformer.resize(image, 2).to_bytes
    half = transformer.resize(image, 0.5)
    assert_equal [75, 60], [half.width, half.height]
    [90, 180, 270].each do |degrees|
      assert_equal reference.rotate(image, degrees).to_bytes, transformer.rotate(image, degrees).to_bytes, "#{degrees}°"
    end
    assert_equal image.to_bytes, transformer.rotate(image, 360).to_bytes
  end

  def test_transformer_arbitrary_rotation
    transformer = ZXingFFI::Transformers::ImageMagickTransformer.new
    image = IMAGES.qr_image(scale: 5)
    [30, -45].each do |degrees|
      out = transformer.rotate(image, degrees, background: 255)
      _, width, height = ZXingFFI::Geometry.rotation_canvas(image.width, image.height, degrees)
      assert_in_delta width, out.width, 2
      assert_in_delta height, out.height, 2
      assert_equal 255, out.to_bytes.getbyte(0), "uncovered corner uses the background"
      barcode = ZXingFFI.read(out).first
      assert_in_delta degrees % 360, barcode.rotation, 3
    end
  end
end
