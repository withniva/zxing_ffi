# frozen_string_literal: true

require "test_helper"
require_relative "../support/fake_transformer"

# Pass ladder, effort levels, stop modes, coordinate mapping, dedupe, filtering.
class StrategyTest < Minitest::Test
  IMAGES = ZXingFFI::SyntheticImages
  STRATEGY = ZXingFFI::Strategy

  def setup
    require_native!
  end

  def page_for(image, dpi: nil)
    ZXingFFI::Loaders::Page.new(number: 1, image: image, dpi: dpi, scale_to_base: 1.0, metadata: {})
  end

  def strategy(passes:, stop: :found, transformer: nil, min_length: {}, config: ZXingFFI.config, **options)
    STRATEGY.new(passes: passes, stop: stop, options: ZXingFFI::Reader::Options.new(options), config: config,
      min_length: min_length, transformer: transformer && -> { transformer })
  end

  def test_passes_for_efforts
    assert_equal %i[base], STRATEGY.passes_for(effort: :fast)
    assert_equal %i[base inverted global_binarizer high_res], STRATEGY.passes_for(effort: :normal)
    assert_equal %i[base inverted global_binarizer high_res tiles rotated_45 denoise], STRATEGY.passes_for(effort: :thorough)
    assert_equal STRATEGY.passes_for, STRATEGY.passes_for(effort: :normal)
  end

  def test_explicit_passes_override_effort
    assert_equal %i[base tiles], STRATEGY.passes_for(effort: :fast, passes: %i[base tiles base])
    assert_equal %i[tiles], STRATEGY.passes_for(passes: ["tiles"])
    assert_raises(ArgumentError) { STRATEGY.passes_for(passes: %i[base magic]) }
    assert_raises(ArgumentError) { STRATEGY.passes_for(passes: []) }
    assert_raises(ArgumentError) { STRATEGY.passes_for(effort: :heroic) }
  end

  def test_validate_stop
    assert_equal :found, STRATEGY.validate_stop(:found)
    assert_equal :exhaustive, STRATEGY.validate_stop(:exhaustive)
    assert_equal 3, STRATEGY.validate_stop(3)
    [0, -1, 1.5, "found", nil].each { |bad| assert_raises(ArgumentError) { STRATEGY.validate_stop(bad) } }
  end

  def test_stop_found_ends_after_the_first_successful_pass
    result = strategy(passes: STRATEGY::PASSES, transformer: ZXingFFI::FakeTransformer.new).run(page_for(IMAGES.qr_image))

    assert_equal %i[base], result.passes_run
    assert_equal [IMAGES::QR_TEXT], result.barcodes.map(&:text)
    assert_equal [:base], result.barcodes.map(&:pass)
  end

  def test_exhaustive_runs_every_pass_and_dedupes_to_the_earliest
    transformer = ZXingFFI::FakeTransformer.new
    result = strategy(passes: %i[base global_binarizer high_res tiles denoise], stop: :exhaustive, transformer: transformer)
      .run(page_for(IMAGES.qr_image))

    expected_passes = %i[base global_binarizer high_res tiles]
    expected_passes << :denoise if ZXingFFI::Native.supports?(:try_denoise)
    assert_equal expected_passes, result.passes_run
    assert_equal 1, result.barcodes.size, "later passes find the same code at the same place"
    assert_equal :base, result.barcodes.first.pass
    assert_equal [[:resize, 2]], transformer.calls
  end

  def test_stop_after_n_distinct_barcodes
    image = two_codes_image
    result = strategy(passes: %i[base global_binarizer tiles], stop: 2).run(page_for(image))
    assert_equal %i[base], result.passes_run
    assert_equal 2, result.barcodes.size

    result = strategy(passes: %i[base global_binarizer tiles], stop: 3).run(page_for(image))
    assert_equal %i[base global_binarizer tiles], result.passes_run
    assert_equal 2, result.barcodes.size, "identical content at two positions is not a duplicate"
  end

  def test_empty_result_runs_the_whole_ladder
    result = strategy(passes: %i[base inverted global_binarizer tiles], try_invert: false).run(page_for(IMAGES.blank(width: 50, height: 40)))

    assert_equal %i[base inverted global_binarizer tiles], result.passes_run
    assert_empty result.barcodes
  end

  # try_invert covers 2D readers only: with it on, the pass is needed only for linear formats.
  def test_inverted_pass_is_skipped_when_try_invert_covers_every_selected_format
    result = strategy(passes: %i[inverted], try_invert: true, formats: %i[qr_code data_matrix]).run(page_for(IMAGES.qr_image))
    assert_match(/try_invert already covers/, result.skipped_passes[:inverted])

    result = strategy(passes: %i[inverted], try_invert: true).run(page_for(IMAGES.qr_image))
    assert_equal %i[inverted], result.passes_run, "linear formats are selected, so the pass runs"
  end

  def test_inverted_pass_finds_white_on_black_linear_codes
    fixture = fixture_path("symbologies", "code_128.pgm")
    skip "symbology fixtures not generated" unless File.exist?(fixture)

    upright = ZXingFFI::Image.from_pgm(File.binread(fixture))
    expected = ZXingFFI.read(upright).first
    negative = upright.inverted
    assert_empty ZXingFFI.read(negative), "zxing-cpp's try_invert does not help linear readers"

    result = strategy(passes: %i[base inverted]).run(page_for(negative)) # library default try_invert: true
    assert_equal [[expected.text, :inverted, true]], result.barcodes.map { |b| [b.text, b.pass, b.inverted?] }
    assert_equal expected.position, result.barcodes.first.position
  end

  def test_inverted_pass_releases_its_copy_and_needs_a_lum_image
    released = []
    image = IMAGES.qr_image
    image.define_singleton_method(:inverted) { super().tap { |copy| released << copy } }
    strategy(passes: %i[inverted], stop: :exhaustive).run(page_for(image))
    assert(released.all?(&:released?))
    assert_equal 1, released.size

    pixels, width, height = IMAGES.render
    rgb = ZXingFFI::Image.new(IMAGES.convert(pixels, :rgb), width: width, height: height, format: :rgb)
    assert_match(/:lum/, strategy(passes: %i[inverted]).run(page_for(rgb)).skipped_passes[:inverted])
  end

  def test_inverted_pass_finds_white_on_black_codes
    image = IMAGES.qr_image(invert: true, canvas: [200, 200], offset: [10, 10])
    result = strategy(passes: %i[base inverted], try_invert: false).run(page_for(image))

    assert_equal %i[base inverted], result.passes_run
    assert_equal [:inverted], result.barcodes.map(&:pass)
    assert result.barcodes.first.inverted?
  end

  def test_global_binarizer_pass_is_skipped_when_already_selected
    result = strategy(passes: %i[global_binarizer], binarizer: :global_histogram).run(page_for(IMAGES.qr_image))
    assert_equal %i[global_binarizer], result.skipped_passes.keys
  end

  def test_tiles_pass_maps_crop_positions_back_to_the_base_image
    image = IMAGES.qr_image(canvas: [3000, 2000], offset: [2500, 1700], scale: 3)
    base = strategy(passes: %i[base]).run(page_for(image)).barcodes.first
    tiled = strategy(passes: %i[tiles]).run(page_for(image)).barcodes

    assert_equal [:tiles], tiled.map(&:pass).uniq
    assert_equal 1, tiled.size, "overlapping tiles must not produce duplicates"
    assert_quads_close base.position, tiled.first.position, 1
  end

  def test_high_res_upscales_small_rasters_and_maps_back
    image = IMAGES.qr_image(scale: 1, quiet: 2, canvas: [120, 90], offset: [30, 20])
    transformer = ZXingFFI::FakeTransformer.new
    result = strategy(passes: %i[high_res], transformer: transformer).run(page_for(image))

    assert_equal [[:resize, 2]], transformer.calls
    barcode = result.barcodes.first
    refute_nil barcode, "the 2x upscale should decode"
    assert_equal :high_res, barcode.pass
    # symbol: offset + 2-module quiet zone, 21 modules of 1 px
    assert_in_delta 30 + 2 + 10.5, barcode.center.x, 1.5
    assert_in_delta 20 + 2 + 10.5, barcode.center.y, 1.5
  end

  def test_high_res_skip_reasons
    big = IMAGES.blank(width: 2000, height: 10)
    assert_match(/already 2000 px/, strategy(passes: %i[high_res], transformer: ZXingFFI::FakeTransformer.new).run(page_for(big)).skipped_passes[:high_res])
    assert_equal "no transformer available", strategy(passes: %i[high_res]).run(page_for(IMAGES.blank)).skipped_passes[:high_res]
    capped = ZXingFFI::Config.new.with(max_pixels: 64 * 64 * 3)
    assert_match(/max_pixels/, strategy(passes: %i[high_res], transformer: ZXingFFI::FakeTransformer.new, config: capped).run(page_for(IMAGES.blank)).skipped_passes[:high_res])
  end

  def test_high_res_rerenders_pdf_pages_at_twice_the_dpi
    base_image = IMAGES.qr_image(scale: 1, quiet: 2, canvas: [150, 120], offset: [40, 30])
    requested = []
    rerender = lambda do |dpi|
      requested << dpi
      hi = IMAGES.qr_image(scale: 2, quiet: 2, canvas: [300, 240], offset: [80, 60])
      page_for(hi, dpi: dpi)
    end
    info = ZXingFFI::Loaders::PageInfo.new(number: 1, width: 150 * 72 / 100.0, height: 120 * 72 / 100.0, unit: :pt, rotation: 0, native_ppi: nil)
    result = strategy(passes: %i[high_res]).run(page_for(base_image, dpi: 100), rerender: rerender, page_info: info)

    assert_equal [200], requested
    barcode = result.barcodes.first
    assert_equal :high_res, barcode.pass
    assert_in_delta 40 + 2 + 10.5, barcode.center.x, 1.5
    assert_in_delta 30 + 2 + 10.5, barcode.center.y, 1.5
  end

  def test_high_res_pdf_skipped_at_max_dpi
    info = ZXingFFI::Loaders::PageInfo.new(number: 1, width: 612, height: 792, unit: :pt, rotation: 0, native_ppi: nil)
    result = strategy(passes: %i[high_res]).run(page_for(IMAGES.blank, dpi: 600), rerender: ->(_) { flunk "must not rerender" }, page_info: info)
    assert_match(/max_dpi/, result.skipped_passes[:high_res])
  end

  def test_rotated_pass_is_limited_to_linear_formats
    result = strategy(passes: %i[rotated_45], formats: %i[qr_code], transformer: ZXingFFI::FakeTransformer.new).run(page_for(IMAGES.qr_image))
    assert_equal({rotated_45: "no linear formats selected"}, result.skipped_passes)

    result = strategy(passes: %i[rotated_45]).run(page_for(IMAGES.qr_image))
    assert_equal({rotated_45: "no transformer available"}, result.skipped_passes)
  end

  def test_rotated_pass_decodes_a_45_degree_linear_code_and_maps_it_back
    fixture = fixture_path("symbologies", "code_128.pgm")
    skip "symbology fixtures not generated yet" unless File.exist?(fixture)

    upright = ZXingFFI::Image.from_pgm(File.binread(fixture))
    expected = ZXingFFI.read(upright).first
    # rotate the code by -45° so that the pass's +45° turns it back to horizontal
    transformer = ZXingFFI::FakeTransformer.new
    tilted = transformer.rotate(upright, -45)
    result = strategy(passes: %i[base rotated_45], stop: :exhaustive, transformer: transformer).run(page_for(tilted))

    rotated = result.barcodes.find { |b| b.pass == :rotated_45 }
    refute_nil rotated, "passes run: #{result.passes_run}, found: #{result.barcodes.map(&:pass)}"
    assert_equal expected.text, rotated.text
    to_tilted, = ZXingFFI::Geometry.rotation_canvas(upright.width, upright.height, -45)
    expected_center = to_tilted.apply(expected.center)
    assert_in_delta expected_center.x, rotated.center.x, 5
    assert_in_delta expected_center.y, rotated.center.y, 5
    assert_includes [315, 135], rotated.rotation, "a horizontal code tilted by -45° has rotation 315 (or 135 when read upside down)"
  end

  # An escalation pass failing must not throw away what earlier passes found (found by the review).
  def test_a_failing_escalation_pass_keeps_earlier_results
    info = ZXingFFI::Loaders::PageInfo.new(number: 1, width: 150 * 72 / 100.0, height: 120 * 72 / 100.0, unit: :pt, rotation: 0, native_ppi: nil)
    rerender = ->(_dpi) { raise ZXingFFI::TimeoutError, "pdftoppm timed out after 3 s" }
    result = strategy(passes: %i[base high_res tiles], stop: :exhaustive)
      .run(page_for(IMAGES.qr_image, dpi: 100), rerender: rerender, page_info: info)

    assert_equal [IMAGES::QR_TEXT], result.barcodes.map(&:text)
    assert_equal %i[base tiles], result.passes_run
    assert_match(/\Afailed: TimeoutError: pdftoppm timed out/, result.skipped_passes[:high_res])
  end

  def test_a_failing_transformer_is_recorded_and_its_pass_skipped
    broken = ZXingFFI::FakeTransformer.new
    broken.define_singleton_method(:rotate) { |*| raise ZXingFFI::RenderError, "magick exited 1" }
    result = strategy(passes: %i[base rotated_45], stop: :exhaustive, transformer: broken).run(page_for(IMAGES.qr_image))

    assert_equal [IMAGES::QR_TEXT], result.barcodes.map(&:text)
    assert_match(/failed: RenderError/, result.skipped_passes[:rotated_45])
  end

  def test_the_first_pass_failing_fails_the_page
    image = IMAGES.qr_image.release!
    assert_raises(ZXingFFI::Error) { strategy(passes: %i[base tiles]).run(page_for(image)) }
  end

  # Transformer passes need :lum; scanning an RGB image at :thorough used to crash (found by the review).
  def test_non_lum_images_skip_the_transformer_passes
    pixels, width, height = IMAGES.render
    rgb = ZXingFFI::Image.new(IMAGES.convert(pixels, :rgb), width: width, height: height, format: :rgb)
    result = strategy(passes: ZXingFFI::Strategy::PASSES, stop: :exhaustive, transformer: ZXingFFI::FakeTransformer.new).run(page_for(rgb))

    assert_equal [IMAGES::QR_TEXT], result.barcodes.map(&:text)
    %i[inverted high_res rotated_45].each { |pass| assert_match(/:lum image/, result.skipped_passes[pass], pass) }
    assert_includes result.passes_run, :tiles
  end

  # The rotated canvas is ~2x the pixels of a square image (found by the review).
  def test_rotated_pass_respects_max_pixels
    image = IMAGES.blank(width: 100, height: 100)
    capped = ZXingFFI::Config.new.with(max_pixels: 100 * 100)
    result = strategy(passes: %i[rotated_45], transformer: ZXingFFI::FakeTransformer.new, config: capped).run(page_for(image))

    assert_match(/rotated canvas 142x142 would exceed max_pixels/, result.skipped_passes[:rotated_45])
  end

  def test_denoise_pass
    result = strategy(passes: %i[base denoise], stop: :exhaustive).run(page_for(IMAGES.qr_image))

    if ZXingFFI::Native.supports?(:try_denoise)
      assert_includes result.passes_run, :denoise
    else
      assert_match(/not supported/, result.skipped_passes[:denoise])
    end
  end

  def test_min_length_filters_before_the_stop_decision
    result = strategy(passes: %i[base global_binarizer], min_length: {qr_code: 100}).run(page_for(IMAGES.qr_image))

    assert_empty result.barcodes
    assert_equal %i[base global_binarizer], result.passes_run
    kept = strategy(passes: %i[base], min_length: {qr_code: IMAGES::QR_TEXT.length}).run(page_for(IMAGES.qr_image))
    assert_equal 1, kept.barcodes.size
  end

  def test_min_length_by_symbology
    result = strategy(passes: %i[base], min_length: {qr_code: 999}).run(page_for(IMAGES.qr_image))
    assert_empty result.barcodes
  end

  def test_deadline_skips_escalation_but_the_first_pass_always_runs
    result = strategy(passes: %i[base global_binarizer tiles], try_invert: false)
      .run(page_for(IMAGES.blank), deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC) - 1)

    assert_equal %i[base], result.passes_run
    assert_equal({global_binarizer: "page timeout", tiles: "page timeout"}, result.skipped_passes)
  end

  def test_rotation_is_reported_for_rotated_symbols
    [[1, 90], [2, 180], [3, 270]].each do |quarter_turns, degrees|
      pixels, width, height = IMAGES.render(rotate: quarter_turns)
      image = ZXingFFI::Image.new(pixels, width: width, height: height)
      assert_equal degrees, strategy(passes: %i[base]).run(page_for(image)).barcodes.first.rotation
    end
  end

  def test_notify_receives_pass_events
    events = []
    strategy(passes: %i[base tiles], stop: :exhaustive).run(page_for(IMAGES.qr_image), notify: ->(e, p) { events << [e, p] })

    assert_equal [%i[pass_completed base], %i[pass_completed tiles]], events.map { |e, p| [e, p[:pass]] }
    assert_equal [1, 0], events.map { |_, p| p[:added] }
    assert events.all? { |_, p| p[:duration] >= 0 }
  end

  def test_derived_images_are_released
    created = []
    transformer = ZXingFFI::FakeTransformer.new
    transformer.define_singleton_method(:resize) { |image, scale| super(image, scale).tap { |img| created << img } }
    transformer.define_singleton_method(:rotate) { |image, deg, background: 255| super(image, deg, background: background).tap { |img| created << img } }
    strategy(passes: %i[high_res tiles rotated_45], stop: :exhaustive, transformer: transformer).run(page_for(IMAGES.qr_image))

    assert_equal 2, created.size
    assert created.all?(&:released?)
  end

  private

  def two_codes_image
    pixels, width, height = IMAGES.render(canvas: [360, 116], offset: [0, 0])
    second, = IMAGES.render(canvas: [360, 116], offset: [240, 0])
    both = pixels.bytes.zip(second.bytes).map { |a, b| [a, b].min }.pack("C*")
    ZXingFFI::Image.new(both, width: width, height: height)
  end

  def assert_quads_close(expected, actual, tolerance)
    expected.to_a.zip(actual.to_a).each do |e, a|
      assert_in_delta e.x, a.x, tolerance
      assert_in_delta e.y, a.y, tolerance
    end
  end
end
