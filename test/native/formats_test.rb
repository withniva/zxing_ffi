# frozen_string_literal: true

require "test_helper"

# Runtime-derived format map, symbol normalization, input conversion.
class FormatsTest < Minitest::Test
  FORMATS = ZXingFFI::Formats

  # Formats whose presence in zxing-cpp 3.x we rely on in tests and docs.
  CORE = %i[
    qr_code micro_qr_code rmqr_code data_matrix aztec pdf417 micropdf417 maxicode
    code_128 code_39 code_93 codabar itf ean_13 ean_8 upc_a upc_e databar databar_expanded databar_limited
  ].freeze

  def setup
    require_native!
  end

  def test_normalize
    assert_equal :ean_13, FORMATS.normalize("EAN-13")
    assert_equal :qr_code, FORMATS.normalize("QR Code")
    assert_equal :ean_upc, FORMATS.normalize("EAN/UPC")
    assert_equal :rmqr_code, FORMATS.normalize("rMQR Code")
    assert_equal :databar_expanded_stacked, FORMATS.normalize("DataBar Expanded Stacked")
    assert_equal :itf_14, FORMATS.normalize("ITF-14")
    assert_equal :a_b, FORMATS.normalize("  --A  //  b--  ")
  end

  def test_readable_formats_cover_the_core_symbologies
    readable = ZXingFFI.formats

    CORE.each { |format| assert_includes readable, format }
    assert readable.all?(Symbol)
    assert_equal readable.uniq, readable
    assert readable.frozen?
  end

  def test_add_on_only_formats_are_known_but_not_readable
    assert_includes FORMATS.all, :ean_2
    assert_includes FORMATS.all, :ean_5
    refute_includes FORMATS.readable, :ean_2
    refute_includes FORMATS.readable, :ean_5
  end

  def test_map_is_bijective_and_round_trips_through_the_library
    table = FORMATS.table
    assert_equal table.by_value.size, table.by_symbol.size

    table.by_value.each do |value, info|
      assert_equal info.symbol, FORMATS.symbol_for(value)
      assert_equal value, FORMATS.value_for(info.symbol)
      assert_equal value, ZXingFFI::Native.ZXing_BarcodeFormatFromString(info.name), "library parses its own name #{info.name}"
      assert_equal info.name, FORMATS.name_for(value)
    end
  end

  # Fails when a new zxing-cpp release adds symbologies: review Formats/linear handling and docs, then update.
  def test_known_readable_formats_snapshot
    expected = %i[
      aztec aztec_code aztec_rune codabar code_128 code_32 code_39 code_39_extended code_39_standard code_93
      compact_pdf417 data_matrix databar databar_expanded databar_expanded_stacked databar_limited databar_omni
      databar_stacked databar_stacked_omni dx_film_edge ean_13 ean_8 ean_upc isbn itf itf_14 maxicode micro_qr_code
      micropdf417 other_barcode pdf417 pharmazentralnummer qr_code qr_code_model_1 qr_code_model_2 rmqr_code telepen
      telepen_alpha telepen_numeric upc_a upc_e
    ]
    assert_equal expected, ZXingFFI.formats.sort
  end

  def test_linear_formats_come_from_the_all_linear_meta_format
    linear = ZXingFFI.linear_formats

    %i[code_128 code_39 ean_13 upc_a itf codabar databar].each { |f| assert_includes linear, f }
    %i[qr_code data_matrix aztec pdf417 maxicode micro_qr_code].each { |f| refute_includes linear, f }
    assert (linear - ZXingFFI.formats).empty?, "linear formats must be readable"
  end

  def test_symbology_family
    ean13 = FORMATS.table.by_symbol.fetch(:ean_13)

    assert_equal :ean_upc, FORMATS.symbol_for(ean13.symbology)
    assert_equal :qr_code, FORMATS.symbol_for(FORMATS.table.by_symbol.fetch(:micro_qr_code).symbology)
  end

  def test_meta_formats_are_resolved_at_runtime
    meta = FORMATS.meta

    %i[all all_readable all_linear all_matrix].each { |m| assert meta.key?(m), m }
    assert_equal meta.values.uniq.size, meta.size
  end

  def test_resolve_all_keeps_the_library_default
    assert_nil FORMATS.resolve(:all)
    assert_nil FORMATS.resolve("all")
    assert_nil FORMATS.resolve("ALL")
    assert_nil FORMATS.resolve(nil)
    assert_nil FORMATS.resolve([:qr_code, :all])
    assert_equal FORMATS.meta[:all_readable], FORMATS.value_for(:all)
  end

  def test_resolve_accepts_symbols_library_strings_and_lists
    qr = FORMATS.value_for(:qr_code)
    ean13 = FORMATS.value_for(:ean_13)

    assert_equal [qr], FORMATS.resolve(:qr_code)
    assert_equal [qr], FORMATS.resolve("QR Code")
    assert_equal [qr], FORMATS.resolve("QRCode")
    assert_equal [qr], FORMATS.resolve("qr_code")
    assert_equal [qr], FORMATS.resolve(:qrcode)
    assert_equal [ean13], FORMATS.resolve("EAN-13")
    assert_equal [qr, ean13], FORMATS.resolve([:qr_code, "EAN-13", :qr_code])
    assert_equal [qr, ean13], FORMATS.resolve("qr_code, ean_13")
    assert_equal [qr, ean13], FORMATS.resolve("QR Code|EAN-13")
    assert_equal [FORMATS.meta[:all_linear]], FORMATS.resolve(:all_linear)
    assert_equal [FORMATS.value_for(:ean_upc)], FORMATS.resolve("EAN/UPC")
  end

  def test_resolve_rejects_unknown_formats_listing_valid_names
    error = assert_raises(ArgumentError) { FORMATS.resolve(:not_a_format) }
    assert_includes error.message, ":not_a_format"
    assert_includes error.message, "qr_code"
    assert_includes error.message, "all_linear"

    assert_raises(ArgumentError) { FORMATS.resolve("bogus") }
    assert_raises(ArgumentError) { FORMATS.resolve([]) }
    assert_raises(ArgumentError) { FORMATS.resolve(",") }
    assert_raises(ArgumentError) { FORMATS.resolve([3.5]) }
    assert_raises(ArgumentError) { FORMATS.value_for(%i[qr_code ean_13]) }
    assert_nil ZXingFFI::Native.last_error_message, "library errors from parsing must be cleared"
  end

  def test_expand_and_linear_subset
    assert_equal %i[ean_upc ean_13 ean_8 upc_a upc_e isbn].sort, FORMATS.expand(:ean_upc).sort
    assert_equal [:ean_13], FORMATS.expand(:ean_13)
    assert_equal ZXingFFI.formats, FORMATS.expand(:all)
    assert_equal [:code_128], FORMATS.linear_subset(%i[qr_code code_128])
    assert_empty FORMATS.linear_subset(%i[qr_code data_matrix])
    assert_equal ZXingFFI.linear_formats.sort, FORMATS.linear_subset(:all).sort
  end

  def test_unknown_values_get_a_name_instead_of_raising
    assert_equal :unknown, FORMATS.symbol_for(0x7777)
  end
end
