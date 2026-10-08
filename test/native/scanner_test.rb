# frozen_string_literal: true

require "test_helper"
require "stringio"

# scan/scan_pages, threads, stop modes, page selection, ordering, instrumentation, errors.
# Uses a fake PDF loader so the orchestration is tested without Poppler.
class ScannerTest < Minitest::Test
  IMAGES = ZXingFFI::SyntheticImages

  # Fake PDF: letter pages; page n has a QR whose top-left corner sits at QR_AT[n] (points). Page 2 is blank,
  # FAIL_PAGES raise RenderError.
  class FakeDocument < ZXingFFI::Loaders::Document
    QR_AT = {1 => [72, 144], 2 => nil, 3 => [300, 500], 4 => [36, 36], 5 => [400, 60]}.freeze

    attr_reader :renders, :closes

    def initialize(source, pages:, fail_pages: [], slow_pages: [])
      super(source)
      @pages = pages
      @fail_pages = fail_pages
      @slow_pages = slow_pages
      @renders = Queue.new
      @closes = 0
    end

    def close
      @closes += 1
    end

    def page_count = @pages

    def page_info(number)
      check_page!(number)
      ZXingFFI::Loaders::PageInfo.new(number: number, width: 612, height: 792, unit: :pt, rotation: 0, native_ppi: nil)
    end

    def render(number, dpi: nil, timeout: nil)
      check_page!(number)
      @renders << [number, dpi]
      raise ZXingFFI::RenderError.new("boom on page #{number}", stderr: "fake", exit_status: 1) if @fail_pages.include?(number)
      sleep 10 if @slow_pages.include?(number) # a slow renderer (interruptible)

      width, height = ZXingFFI::Dpi.dimensions(612, 792, dpi)
      at = QR_AT[number]
      scale = [(dpi / 36.0).round, 1].max
      pixels =
        if at
          IMAGES.render(scale: scale, quiet: 0, canvas: [width, height], offset: at.map { |v| (v * dpi / 72.0).round }).first
        else
          ("\xFF".b * (width * height))
        end
      image = ZXingFFI::Image.new(pixels, width: width, height: height)
      ZXingFFI::Loaders::Page.new(number: number, image: image, dpi: dpi, scale_to_base: 1.0, metadata: {loader: :fake})
    end
  end

  def setup
    require_native!
    @documents = []
  end

  # Routes the :poppler loader to a fake that opens FakeDocuments.
  def with_fake_pdf(pages: 3, fail_pages: [], slow_pages: [])
    documents = @documents
    loader = Class.new(ZXingFFI::Loaders::Base) do
      define_singleton_method(:loader_name) { :poppler }
      define_singleton_method(:kinds) { [:pdf] }
      define_singleton_method(:probe) { true }
      define_method(:open) do |source, password: nil|
        raise ZXingFFI::PasswordRequired, "needs a password" if password == "wrong"

        FakeDocument.new(source, pages: pages, fail_pages: fail_pages, slow_pages: slow_pages).tap { |doc| documents << doc }
      end
    end
    original = ZXingFFI::Loaders.method(:fetch)
    ZXingFFI::Loaders.define_singleton_method(:fetch) { |name| (name.to_sym == :poppler) ? loader : original.call(name) }
    in_tmpdir do |dir|
      path = File.join(dir, "fake.pdf")
      File.binwrite(path, "%PDF-1.7\n% fake\n")
      yield path
    end
  ensure
    ZXingFFI::Loaders.define_singleton_method(:fetch, original) if original
  end

  def test_scan_an_image
    barcodes = ZXingFFI.scan(IMAGES.qr_image)

    assert_equal [IMAGES::QR_TEXT], barcodes.map(&:text)
    barcode = barcodes.first
    assert_equal 1, barcode.page
    assert_equal :base, barcode.pass
    assert_nil barcode.dpi
    assert_nil barcode.page_position
  end

  def test_scan_does_not_release_a_caller_image
    image = IMAGES.qr_image
    ZXingFFI.scan(image)
    refute image.released?
  end

  def test_scan_pages_without_a_block_returns_an_enumerator
    enum = ZXingFFI.scan_pages(IMAGES.qr_image)

    assert_kind_of Enumerator, enum
    results = enum.to_a
    assert_equal 1, results.size
    assert_kind_of ZXingFFI::PageResult, results.first
  end

  def test_page_result_fields
    result = ZXingFFI.scan_pages(IMAGES.qr_image(canvas: [300, 200])).first

    assert_equal 1, result.page
    assert_equal [300, 200], [result.width, result.height]
    assert_nil result.dpi
    assert_equal %i[base], result.passes_run
    assert_equal({}, result.skipped_passes)
    assert_nil result.error
    assert_operator result.duration, :>, 0
    assert_equal :image, result.metadata[:loader]
  end

  def test_pdf_pages_positions_and_page_coordinates
    with_fake_pdf(pages: 3) do |path|
      results = ZXingFFI.scan_pages(path, dpi: 144).to_a

      assert_equal [1, 2, 3], results.map(&:page)
      assert_equal [1, 0, 1], results.map { |r| r.barcodes.size }
      assert_equal [144, 144, 144], results.map(&:dpi)
      assert_equal [1224, 1584], [results.first.width, results.first.height]

      barcode = results.first.barcodes.first
      assert_equal 1, barcode.page
      assert_equal 144, barcode.dpi
      # QR top-left at (72, 144) pt; symbol side = 21 modules × 4 px at 144 DPI = 84 px = 42 pt
      assert_in_delta 72, barcode.page_position.top_left.x, 1
      assert_in_delta 144, barcode.page_position.top_left.y, 1
      assert_in_delta 72 + 21, barcode.page_position.center.x, 1
      assert_in_delta 144, barcode.position.top_left.x, 2
      assert_in_delta 288, barcode.position.top_left.y, 2
      assert_equal :explicit, results.first.metadata[:dpi_source]
      refute results.first.metadata[:dpi_capped]
    end
  end

  def test_scan_returns_barcodes_in_page_order
    with_fake_pdf(pages: 5) do |path|
      assert_equal [1, 3, 4, 5], ZXingFFI.scan(path, dpi: 72).map(&:page)
    end
  end

  def test_auto_dpi_uses_default_dpi_for_born_digital_pages
    with_fake_pdf(pages: 1) do |path|
      result = ZXingFFI.scan_pages(path, max_dpi: 200).first
      assert_equal 200, result.dpi
      assert_equal :default, result.metadata[:dpi_source]
    end
  end

  def test_pixel_cap_lowers_the_dpi
    with_fake_pdf(pages: 1) do |path|
      result = ZXingFFI.scan_pages(path, dpi: 300, max_pixels: 1_000_000).first
      assert_operator result.dpi, :<, 300
      assert result.metadata[:dpi_capped]
      assert_operator result.width * result.height, :<=, 1_000_000
    end
  end

  def test_page_selection
    with_fake_pdf(pages: 5) do |path|
      assert_equal [3, 4, 5], ZXingFFI.scan_pages(path, dpi: 72, pages: 3..).map(&:page)
      assert_equal [2, 3], ZXingFFI.scan_pages(path, dpi: 72, pages: 2...4).map(&:page)
      assert_equal [1, 5], ZXingFFI.scan_pages(path, dpi: 72, pages: [5, 1, 5]).map(&:page)
      assert_equal [4], ZXingFFI.scan_pages(path, dpi: 72, pages: 4).map(&:page)
      assert_equal [4, 5], ZXingFFI.scan_pages(path, dpi: 72, pages: 4..99).map(&:page)
      error = assert_raises(ArgumentError) { ZXingFFI.scan(path, dpi: 72, pages: [9]) }
      assert_match(/outside 1..5/, error.message)
    end
  end

  def test_max_pages_counts_selected_pages
    with_fake_pdf(pages: 5) do |path|
      error = assert_raises(ZXingFFI::LimitExceeded) { ZXingFFI.scan(path, dpi: 72, max_pages: 2) }
      assert_equal :max_pages, error.limit
      assert_equal 5, error.value
      assert_equal 2, ZXingFFI.scan_pages(path, dpi: 72, max_pages: 2, pages: 1..2).count
    end
  end

  def test_on_page_error_raise_is_the_default
    with_fake_pdf(pages: 3, fail_pages: [2]) do |path|
      error = assert_raises(ZXingFFI::RenderError) { ZXingFFI.scan(path, dpi: 72) }
      assert_match(/page 2/, error.message)
    end
  end

  def test_on_page_error_skip_records_the_error
    with_fake_pdf(pages: 3, fail_pages: [2]) do |path|
      results = ZXingFFI.scan_pages(path, dpi: 72, on_page_error: :skip).to_a

      assert_equal [1, 2, 3], results.map(&:page)
      assert_kind_of ZXingFFI::RenderError, results[1].error
      assert_empty results[1].barcodes
      assert_nil results[0].error
      assert_equal [1, 3], ZXingFFI.scan(path, dpi: 72, on_page_error: :skip).map(&:page)
    end
  end

  def test_threads_produce_the_same_results_as_serial
    with_fake_pdf(pages: 5) do |path|
      serial = ZXingFFI.scan_pages(path, dpi: 72).map { |r| [r.page, signature(r.barcodes)] }
      threaded = ZXingFFI.scan_pages(path, dpi: 72, threads: 4).map { |r| [r.page, signature(r.barcodes)] }

      assert_equal serial, threaded
      assert_equal (1..5).to_a, threaded.map(&:first), "scan_pages yields in page order"
    end
  end

  def test_threads_propagate_page_errors
    with_fake_pdf(pages: 5, fail_pages: [4]) do |path|
      assert_raises(ZXingFFI::RenderError) { ZXingFFI.scan(path, dpi: 72, threads: 3) }
      results = ZXingFFI.scan_pages(path, dpi: 72, threads: 3, on_page_error: :skip).to_a
      assert_equal [4], results.select(&:error).map(&:page)
    end
  end

  def test_breaking_out_early_stops_the_workers
    with_fake_pdf(pages: 5) do |path|
      threads_before = Thread.list.size
      first = ZXingFFI.scan_pages(path, dpi: 72, threads: 2).first
      assert_equal 1, first.page
      assert_equal threads_before, Thread.list.size, "worker threads must be joined after an early break"
    end
  end

  def test_document_is_closed_even_after_errors
    with_fake_pdf(pages: 2, fail_pages: [2]) do |path|
      ZXingFFI.scan(path, dpi: 72, on_page_error: :skip)
      assert_raises(ZXingFFI::RenderError) { ZXingFFI.scan(path, dpi: 72) }
      assert_equal [1, 1], @documents.map(&:closes)
    end
  end

  # Leaving early must not wait for pages still rendering on other threads (found by the review: 40 s vs 3 s).
  def test_leaving_early_does_not_wait_for_pages_in_progress
    with_fake_pdf(pages: 5, slow_pages: [3, 4, 5]) do |path|
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      first = ZXingFFI.scan_pages(path, dpi: 72, threads: 3).first
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      assert_equal 1, first.page
      assert_operator elapsed, :<, 5, "workers rendering slow pages must be stopped, not awaited"
      assert_equal [1], @documents.map(&:closes)
    end
  end

  def test_instrument_events
    events = []
    ZXingFFI.scan(IMAGES.qr_image, instrument: ->(event, payload) { events << [event, payload] })

    assert_equal %i[page_loaded pass_completed page_completed], events.map(&:first)
    assert_equal 1, events[0][1][:page]
    assert_equal :base, events[1][1][:pass]
    assert_equal 1, events[1][1][:page]
    assert_equal 1, events[2][1][:barcodes]
    assert_equal %i[base], events[2][1][:passes_run]
  end

  def test_instrument_events_with_threads_are_serialized
    with_fake_pdf(pages: 5) do |path|
      events = []
      ZXingFFI.scan(path, dpi: 72, threads: 4, instrument: ->(event, payload) { events << [event, payload[:page]] })
      completed = events.filter_map { |event, page| page if event == :page_completed }
      assert_equal (1..5).to_a, completed.sort
    end
  end

  def test_ordering_top_to_bottom_left_to_right
    pixels, width, height = IMAGES.render(canvas: [600, 500], offset: [400, 20])
    [[20, 30], [20, 300], [400, 330]].each do |x, y|
      more, = IMAGES.render(canvas: [600, 500], offset: [x, y])
      pixels = pixels.bytes.zip(more.bytes).map(&:min).pack("C*")
    end
    barcodes = ZXingFFI.scan(ZXingFFI::Image.new(pixels, width: width, height: height), stop: :exhaustive)
    centers = barcodes.map { |b| [b.center.x.round, b.center.y.round] }

    assert_equal 4, barcodes.size
    # (20,30) and (400,20) are one row; (20,300) and (400,330) the next
    assert_equal [[20, 30], [400, 20], [20, 300], [400, 330]].map { |x, y| [x + 58, y + 58] }, centers
  end

  def test_order_helper_buckets_rows
    quad = ->(x, y, h = 40) { ZXingFFI::Geometry::Quad.from_points([[x, y], [x + 40, y], [x + 40, y + h], [x, y + h]]) }
    fake = Struct.new(:name, :position) do
      def center = position.center
    end
    items = [fake.new("b", quad.call(200, 12)), fake.new("a", quad.call(10, 20)), fake.new("c", quad.call(10, 200)), fake.new("d", quad.call(5, 80, 2))]

    assert_equal %w[a b d c], ZXingFFI::Scanner.order(items).map(&:name)
  end

  def test_io_input_is_spooled
    pgm = IMAGES.qr_image.to_pgm
    assert_equal [IMAGES::QR_TEXT], ZXingFFI.scan(StringIO.new(pgm)).map(&:text)
  end

  def test_pnm_file_input
    in_tmpdir do |dir|
      path = File.join(dir, "code.pgm")
      File.binwrite(path, IMAGES.qr_image.to_pgm)
      assert_equal [IMAGES::QR_TEXT], ZXingFFI.scan(path, loader: :pnm).map(&:text)
      assert_equal [IMAGES::QR_TEXT], ZXingFFI.scan(Pathname(path), loader: :pnm).map(&:text)
    end
  end

  def test_unsupported_input
    in_tmpdir do |dir|
      path = File.join(dir, "notes.txt")
      File.write(path, "just some text\n")
      assert_raises(ZXingFFI::UnsupportedInput) { ZXingFFI.scan(path) }
    end
    assert_raises(ZXingFFI::UnsupportedInput) { ZXingFFI.scan(42) }
    assert_raises(Errno::ENOENT) { ZXingFFI.scan("/definitely/not/here.png") }
  end

  def test_password_errors_propagate
    with_fake_pdf(pages: 1) do |path|
      assert_raises(ZXingFFI::PasswordRequired) { ZXingFFI.scan(path, password: "wrong") }
    end
  end

  def test_option_validation
    image = IMAGES.qr_image
    {
      effort: :extreme, stop: :never, dpi: 0, pages: 0, threads: 0, on_page_error: :ignore, timeout: -1,
      instrument: 42, min_length: {nope: 3}, passes: %i[x], formats: :nope, bogus: 1, oversize: :shrink,
      max_source_pixels: 0
    }.each do |key, value|
      assert_raises(ArgumentError, "#{key}: #{value.inspect}") { ZXingFFI.scan(image, key => value) }
    end
    assert_raises(ArgumentError) { ZXingFFI.scan(image, min_length: {qr_code: -1}) }
    assert_raises(ArgumentError) { ZXingFFI.scan(image, pages: [1, "2"]) }
  end

  def test_reader_options_pass_through
    assert_equal [IMAGES::QR_TEXT.unpack1("H*").upcase.scan(/../).join(" ")], ZXingFFI.scan(IMAGES.qr_image, text_mode: :hex).map(&:text)
    assert_empty ZXingFFI.scan(IMAGES.qr_image, formats: :ean_13, effort: :fast)
  end

  def test_timeout_limits_escalation
    result = ZXingFFI.scan_pages(IMAGES.blank(width: 300, height: 300), effort: :thorough, timeout: 1e-9, try_invert: false).first

    assert_equal %i[base], result.passes_run
    refute_empty result.skipped_passes
    assert_equal ["page timeout"], result.skipped_passes.values.uniq
  end

  private

  def signature(barcodes)
    barcodes.map { |b| [b.text, b.format, b.position.to_a.map(&:to_a), b.page, b.pass] }
  end
end
