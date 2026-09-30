# frozen_string_literal: true

require "test_helper"

# DPI selection and pixel cap.
class DpiTest < Minitest::Test
  DPI = ZXingFFI::Dpi
  LETTER = {width_pt: 612, height_pt: 792}.freeze

  def test_dimensions_round_up_like_poppler
    assert_equal [2550, 3300], DPI.dimensions(612, 792, 300)
    assert_equal [60, 77], DPI.dimensions(612, 792, 7) # 59.5 → 60 (verified against pdftoppm 26.07)
    assert_equal [859, 1111], DPI.dimensions(612, 792, 101)
    assert_equal 2550 * 3300, DPI.pixels(612, 792, 300)
  end

  def test_auto_uses_default_dpi_for_born_digital_pages
    choice = DPI.choose(requested: :auto, **LETTER, native_ppi: nil)

    assert_equal 300, choice.dpi
    assert_equal :default, choice.source
    assert_equal :auto, choice.requested
    refute choice.capped
    assert_equal 300, DPI.choose(requested: nil, **LETTER).dpi
  end

  def test_auto_default_respects_max_dpi
    assert_equal 200, DPI.choose(requested: :auto, **LETTER, default_dpi: 300, max_dpi: 200).dpi
  end

  def test_auto_uses_native_ppi_clamped_to_150_600
    assert_equal 200, DPI.choose(requested: :auto, **LETTER, native_ppi: 200).dpi
    assert_equal :native, DPI.choose(requested: :auto, **LETTER, native_ppi: 200).source
    assert_equal 150, DPI.choose(requested: :auto, **LETTER, native_ppi: 72).dpi
    assert_equal 600, DPI.choose(requested: :auto, **LETTER, native_ppi: 1200, max_pixels: nil).dpi
    assert_equal 400, DPI.choose(requested: :auto, **LETTER, native_ppi: 1200, max_dpi: 400).dpi
    assert_equal 204, DPI.choose(requested: :auto, **LETTER, native_ppi: 204.4).dpi
    assert_equal 300, DPI.choose(requested: :auto, **LETTER, native_ppi: 0).dpi
  end

  def test_explicit_dpi_is_honored_even_above_max_dpi
    choice = DPI.choose(requested: 900, **LETTER, max_dpi: 600, max_pixels: nil)

    assert_equal 900, choice.dpi
    assert_equal :explicit, choice.source
  end

  def test_pixel_cap_lowers_dpi
    choice = DPI.choose(requested: 1200, **LETTER, max_pixels: 64_000_000)

    assert choice.capped
    assert_operator DPI.pixels(612, 792, choice.dpi), :<=, 64_000_000
    assert_operator DPI.pixels(612, 792, choice.dpi + 1), :>, 64_000_000
  end

  def test_huge_declared_page_is_capped
    # 200 × 200 inch page: 300 DPI would be 3.6 gigapixels
    choice = DPI.choose(requested: :auto, width_pt: 14_400, height_pt: 14_400, max_pixels: 64_000_000)

    assert choice.capped
    assert_equal 40, choice.dpi
    assert_operator DPI.pixels(14_400, 14_400, choice.dpi), :<=, 64_000_000
  end

  def test_max_dpi_for_is_the_highest_fitting_integer
    [[612, 792, 1_000_000], [14_400, 14_400, 64_000_000], [100, 5000, 10_000], [595.28, 841.89, 8_294_400]].each do |w, h, cap|
      dpi = DPI.max_dpi_for(w, h, cap)
      assert_operator DPI.pixels(w, h, dpi), :<=, cap
      assert_operator DPI.pixels(w, h, dpi + 1), :>, cap
    end
  end

  def test_absurd_pages_get_a_fractional_dpi
    # 1e6 pt ≈ 13,889 in: even 1 DPI would be 193 MP
    choice = DPI.choose(requested: :auto, width_pt: 1e6, height_pt: 1e6, max_pixels: 64_000_000)

    assert_in_delta 0.576, choice.dpi, 1e-9
    assert choice.capped
    assert_operator DPI.pixels(1e6, 1e6, choice.dpi), :<=, 64_000_000
    assert_operator DPI.pixels(1e6, 1e6, choice.dpi + 0.001), :>, 64_000_000
  end

  def test_limit_exceeded_when_not_even_one_dpi_fits
    error = assert_raises(ZXingFFI::LimitExceeded) { DPI.choose(requested: :auto, width_pt: 1e7, height_pt: 1e7, max_pixels: 100) }

    assert_equal :max_pixels, error.limit
    assert_operator error.value, :>, 100
  end

  def test_max_dpi_below_the_auto_range
    assert_equal 149, DPI.choose(requested: :auto, **LETTER, native_ppi: 200, max_dpi: 149).dpi
    assert_equal 100, DPI.choose(requested: :auto, **LETTER, native_ppi: 72, max_dpi: 100).dpi
  end

  def test_page_sizes_must_be_finite_and_positive
    [[0, 792], [612, -1], [Float::INFINITY, 792], [612, Float::NAN], [nil, 792]].each do |w, h|
      assert_raises(ArgumentError, [w, h].inspect) { DPI.choose(requested: :auto, width_pt: w, height_pt: h) }
      assert_raises(ArgumentError, [w, h].inspect) { DPI.max_dpi_for(w, h, 1_000_000) }
    end
  end

  def test_invalid_requests
    assert_raises(ArgumentError) { DPI.choose(requested: 0, **LETTER) }
    assert_raises(ArgumentError) { DPI.choose(requested: -72, **LETTER) }
    assert_raises(ArgumentError) { DPI.choose(requested: "300", **LETTER) }
    assert_raises(ArgumentError) { DPI.choose(requested: 300.0, **LETTER) }
  end

  def test_high_res_pass_dpi
    assert_equal 600, DPI.high_res(300, **LETTER)
    assert_equal 400, DPI.high_res(200, **LETTER)
    assert_nil DPI.high_res(600, **LETTER), "already at max_dpi"
    assert_equal 500, DPI.high_res(300, **LETTER, max_dpi: 500)
    capped = DPI.high_res(300, **LETTER, max_pixels: 40_000_000)
    assert_operator capped, :>, 300
    assert_operator DPI.pixels(612, 792, capped), :<=, 40_000_000
    assert_nil DPI.high_res(300, **LETTER, max_pixels: DPI.pixels(612, 792, 300))
  end
end
