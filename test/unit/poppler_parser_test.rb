# frozen_string_literal: true

require "test_helper"

# Parsing of pdfinfo and pdfimages -list output from recorded samples (test/fixtures/samples, Poppler 26.07).
class PopplerParserTest < Minitest::Test
  PARSER = ZXingFFI::Loaders::PopplerLoader::Parser

  def sample(name)
    File.read(fixture_path("samples", name))
  end

  def test_info
    assert_equal({pages: 3, encrypted: false}, PARSER.info(sample("pdfinfo_multipage.txt")))
    assert_equal({pages: 1, encrypted: true}, PARSER.info(sample("pdfinfo_encrypted.txt")))
  end

  def test_info_without_page_count_raises
    assert_raises(ZXingFFI::RenderError) { PARSER.info("Title: nothing useful\n") }
    assert_raises(ZXingFFI::RenderError) { PARSER.info(sample("pdfinfo_password_error.txt")) }
  end

  def test_page_boxes_with_rotation_and_decimal_sizes
    boxes = PARSER.page_boxes(sample("pdfinfo_pages_rotate_mixed.txt"))

    assert_equal [1, 2, 3, 4], boxes.keys
    assert_equal({rotation: 0, width: 612.0, height: 792.0}, boxes[1])
    assert_equal 90, boxes[2][:rotation]
    assert_equal({rotation: 180, width: 595.28, height: 841.89}, boxes[3])
    assert_equal({rotation: 270, width: 792.0, height: 612.0}, boxes[4])
  end

  def test_page_boxes_in_scientific_notation
    boxes = PARSER.page_boxes(sample("pdfinfo_pages_huge.txt"))
    assert_equal 1_000_000.0, boxes.fetch(1)[:width]
    assert_equal 1_000_000.0, boxes.fetch(1)[:height]
  end

  # Malformed PDFs: pdfinfo prints what the MediaBox says (found by the review).
  def test_page_boxes_reject_unusable_sizes
    ["0 x 792", "inf x 792", "612 x nan", "-612 x 792", "abc x 792"].each do |size|
      assert_raises(ZXingFFI::RenderError, size) { PARSER.page_boxes("Page    1 size: #{size} pts\n") }
    end
  end

  def test_page_boxes_handles_negative_rotation_and_missing_rot_lines
    boxes = PARSER.page_boxes("Page    1 size: 100 x 200 pts\nPage    2 size: 10 x 20 pts\nPage    2 rot: -90\n")
    assert_equal 0, boxes[1][:rotation]
    assert_equal 270, boxes[2][:rotation]
  end

  def test_images_skip_headers_and_masks
    images = PARSER.images(sample("pdfimages_embedded.txt"))

    assert_equal 4, images.size, "the smask row is not an image"
    assert images.all? { |i| i[:type] == "image" && i[:page] == 1 }
    assert_equal({page: 1, type: "image", width: 222, height: 222, x_ppi: 144.0, y_ppi: 144.0}, images.first)
    assert_empty PARSER.images(sample("pdfimages_none.txt"))
    assert_empty PARSER.images("")
  end

  # Inline images print "[inline]" (one token) in the object ID column instead of "23 0" (two tokens).
  def test_images_with_inline_image_rows
    images = PARSER.images(sample("pdfimages_inline.txt"))

    assert_equal 13, images.size
    assert_equal({page: 1, type: "image", width: 154, height: 80, x_ppi: 144.0, y_ppi: 240.0}, images[0])
    assert_equal({page: 1, type: "image", width: 50, height: 50, x_ppi: 72.0, y_ppi: 88.0}, images[2])
  end

  def test_images_skip_unparseable_rows
    assert_empty PARSER.images("   1     0 image  wide  tall  rgb 3 8 image no 5 0 x y 1K 1%\n")
  end

  def test_images_with_anisotropic_resolution
    fax = PARSER.images(sample("pdfimages_fax.txt")).first
    assert_equal [204.0, 98.0], fax.values_at(:x_ppi, :y_ppi)
  end

  def test_native_ppi_of_a_full_page_scan
    images = PARSER.images(sample("pdfimages_scanned_jpeg.txt"))
    assert_equal 200.0, PARSER.native_ppi(images, 612, 792)
  end

  def test_native_ppi_uses_the_higher_axis_for_fax
    images = PARSER.images(sample("pdfimages_fax.txt"))
    assert_equal 204.0, PARSER.native_ppi(images, 612, 792)
  end

  def test_native_ppi_ignores_small_embedded_images
    images = PARSER.images(sample("pdfimages_embedded.txt"))
    assert_nil PARSER.native_ppi(images, 612, 792)
    assert_nil PARSER.native_ppi(PARSER.images(sample("pdfimages_multipage_mixed.txt")).select { |i| i[:page] == 1 }, 612, 792)
  end

  def test_native_ppi_coverage_threshold
    half_page = [{page: 1, type: "image", width: 612, height: 396, x_ppi: 72.0, y_ppi: 72.0}]
    assert_equal 72.0, PARSER.native_ppi(half_page, 612, 792)
    assert_nil PARSER.native_ppi(half_page, 612, 792, coverage: 0.6)
    assert_nil PARSER.native_ppi(half_page, 0, 792)
    assert_nil PARSER.native_ppi([{page: 1, type: "image", width: 10, height: 10, x_ppi: 0.0, y_ppi: 0.0}], 612, 792)
  end
end
