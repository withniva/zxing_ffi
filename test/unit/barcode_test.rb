# frozen_string_literal: true

require "test_helper"
require "json"

# ZXingFFI::Barcode value object.
class BarcodeTest < Minitest::Test
  def build(**overrides)
    quad = ZXingFFI::Geometry::Quad.from_points([[10, 20], [110, 20], [110, 120], [10, 120]])
    ZXingFFI::Barcode.new(
      text: "hello", bytes: "hello".b, format: :qr_code, symbology: :qr_code, format_name: "QR Code",
      content_type: :text, symbology_identifier: "]Q1", position: quad, page_position: nil, rotation: 90,
      mirrored: false, inverted: true, eci: false, valid: true, error: nil, line_count: 0, sequence: nil,
      extra_json: '{"ECLevel":"M","Version":"1"}', page: nil, pass: nil, dpi: nil, **overrides
    )
  end

  def test_is_immutable_data
    barcode = build

    assert barcode.frozen?
    assert_raises(NoMethodError) { barcode.text = "x" }
    assert_equal build, barcode
    assert_equal build.hash, barcode.hash
  end

  def test_predicates
    barcode = build

    refute barcode.mirrored?
    assert barcode.inverted?
    refute barcode.eci?
    assert barcode.valid?
  end

  def test_extra_is_parsed_lazily_and_memoized
    barcode = build

    assert_equal({"ECLevel" => "M", "Version" => "1"}, barcode.extra)
    assert_same barcode.extra, barcode.extra
    assert barcode.extra.frozen?
    assert_equal({}, build(extra_json: nil).extra)
    assert_equal({}, build(extra_json: "").extra)
  end

  def test_extra_json_defaults_to_nil
    fields = build.to_h.except(:extra, :bytes_encoding).merge(bytes: "hello".b, position: build.position)
    barcode = ZXingFFI::Barcode.new(**fields)

    assert_nil barcode.extra_json
    assert_equal({}, barcode.extra)
  end

  def test_with_returns_an_updated_copy_with_its_own_extra_cache
    barcode = build
    barcode.extra
    moved = barcode.with(page: 2, pass: :tiles, dpi: 300)

    assert_equal [2, :tiles, 300], [moved.page, moved.pass, moved.dpi]
    assert_nil barcode.page
    assert_equal barcode.extra, moved.extra
    assert_equal({"a" => 1}, barcode.with(extra_json: '{"a":1}').extra)
  end

  def test_center
    assert_equal ZXingFFI::Geometry::Point.new(60, 70), build.center
  end

  def test_to_h_for_text_content
    h = build.to_h

    assert_equal "hello", h[:bytes]
    assert_equal Encoding::UTF_8, h[:bytes].encoding
    refute h.key?(:bytes_encoding)
    refute h.key?(:extra_json)
    assert_equal({"ECLevel" => "M", "Version" => "1"}, h[:extra])
    assert_equal({x: 10, y: 20}, h[:position][:top_left])
    assert_nil h[:page_position]
    JSON.generate(h) # must be JSON-serializable
  end

  def test_to_h_base64_encodes_binary_content
    h = build(content_type: :binary, bytes: "\x00\xFF\x80".b).to_h

    assert_equal ["\x00\xFF\x80".b].pack("m0"), h[:bytes]
    assert_equal "base64", h[:bytes_encoding]
    JSON.generate(h)
  end

  def test_to_h_base64_encodes_text_that_is_not_utf8
    h = build(bytes: "caf\xE9".b).to_h # ISO-8859-1 payload

    assert_equal "base64", h[:bytes_encoding]
    assert_equal "caf\xE9".b, h[:bytes].unpack1("m0")
  end

  def test_to_h_includes_page_position
    page_quad = ZXingFFI::Geometry::Quad.from_points([[1, 2], [3, 2], [3, 4], [1, 4]])
    h = build(page_position: page_quad, page: 1).to_h

    assert_equal({x: 3, y: 4}, h[:page_position][:bottom_right])
    assert_equal 1, h[:page]
  end
end
