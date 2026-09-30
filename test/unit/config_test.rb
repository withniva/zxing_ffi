# frozen_string_literal: true

require "test_helper"

# Configuration.
class ConfigTest < Minitest::Test
  def test_defaults
    config = ZXingFFI::Config.new

    assert_equal %i[poppler vips], config.pdf_loaders
    assert_equal %i[vips image_magick pnm], config.image_loaders
    assert_equal %i[vips image_magick], config.transformers
    assert_equal 300, config.default_dpi
    assert_equal 600, config.max_dpi
    assert_equal 64_000_000, config.max_pixels
    assert_nil config.max_pages
    assert_equal 60, config.render_timeout
    assert_equal 2 * 1024**3, config.subprocess_memory_limit
    assert_equal({pdftoppm: "pdftoppm", pdfinfo: "pdfinfo", pdfimages: "pdfimages", magick: nil}, config.tool_paths)
    assert config.vips_block_untrusted
  end

  def test_library_path_defaults_to_zxing_lib
    with_env("ZXING_LIB" => "/tmp/libZXing.so") { assert_equal "/tmp/libZXing.so", ZXingFFI::Config.new.library_path }
    with_env("ZXING_LIB" => nil) { assert_nil ZXingFFI::Config.new.library_path }
  end

  def test_configure_yields_the_global_config
    returned = ZXingFFI.configure do |c|
      c.max_pixels = 1_000
      c.tool_paths[:pdftoppm] = "/opt/poppler/bin/pdftoppm"
    end

    assert_same ZXingFFI.config, returned
    assert_equal 1_000, ZXingFFI.config.max_pixels
    assert_equal "/opt/poppler/bin/pdftoppm", ZXingFFI.config.tool_path(:pdftoppm)
  end

  def test_reset_config
    ZXingFFI.config.max_dpi = 1
    ZXingFFI.reset_config!
    assert_equal 600, ZXingFFI.config.max_dpi
  end

  def test_tool_path_falls_back_to_default_names
    config = ZXingFFI::Config.new
    config.tool_paths = {}

    assert_equal "pdfinfo", config.tool_path(:pdfinfo)
    assert_nil config.tool_path(:magick)
    assert_nil config.tool_path(:unknown)
  end

  def test_with_returns_an_independent_copy
    config = ZXingFFI::Config.new
    copy = config.with(max_dpi: 200, render_timeout: 5)

    assert_equal 200, copy.max_dpi
    assert_equal 5, copy.render_timeout
    assert_equal 600, config.max_dpi
    copy.tool_paths[:pdfinfo] = "/x/pdfinfo"
    assert_equal "pdfinfo", config.tool_path(:pdfinfo)
    assert_raises(ArgumentError) { config.with(nonsense: 1) }
  end

  def test_to_h_lists_every_setting
    keys = ZXingFFI::Config.new.to_h.keys

    assert_equal %i[library_path pdf_loaders image_loaders transformers default_dpi max_dpi max_pixels max_pages
      render_timeout subprocess_memory_limit tool_paths vips_block_untrusted], keys
  end

  def test_config_is_reset_between_tests_part_one
    ZXingFFI.config.max_pages = 3
    assert_equal 3, ZXingFFI.config.max_pages
  end

  def test_config_is_reset_between_tests_part_two
    assert_nil ZXingFFI.config.max_pages
  end
end
