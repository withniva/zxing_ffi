# frozen_string_literal: true

require "test_helper"

# Lifetime bugs under GC stress and RSS stability over many decodes.
class MemoryTest < Minitest::Test
  IMAGES = ZXingFFI::SyntheticImages

  def setup
    require_native!
  end

  def test_decoding_under_gc_stress
    image = IMAGES.qr_image(scale: 2)
    ZXingFFI.read(image) # warm up: formats table, library defaults, autoloads

    results = []
    GC.stress = true
    begin
      5.times do
        results << ZXingFFI.read(image, return_errors: true).map { |b| [b.text, b.bytes, b.format, b.position.to_a, b.extra] }
        results << ZXingFFI.read(IMAGES.qr_image(scale: 2), formats: [:qr_code]).map(&:text)
        ZXingFFI::Reader.read(image, {}, crop: [0, 0, 20, 20])
      end
    ensure
      GC.stress = false
    end

    expected = [IMAGES::QR_TEXT, IMAGES::QR_TEXT.b, :qr_code]
    results.each_slice(2) do |full, texts|
      assert_equal expected, full.first.first(3)
      assert_equal [IMAGES::QR_TEXT], texts
    end
  end

  def test_released_images_and_results_survive_compaction
    skip "GC.compact unavailable" unless GC.respond_to?(:compact)

    image = IMAGES.qr_image
    barcodes = ZXingFFI.read(image)
    GC.compact
    assert_equal IMAGES::QR_TEXT, barcodes.first.text
    assert_equal [IMAGES::QR_TEXT], ZXingFFI.read(image).map(&:text)
    image.release!
    GC.compact
  end

  # 5,000 decodes of the same image must not grow RSS beyond a small threshold.
  def test_rss_is_stable_over_many_decodes
    iterations = Integer(ENV.fetch("ZXING_RSS_ITERATIONS", 5_000))
    image = IMAGES.qr_image(scale: 2)

    500.times { ZXingFFI.read(image) } # warm up allocator pools
    GC.start
    before = rss_kb
    skip "cannot measure RSS on this platform" unless before

    iterations.times do |i|
      ZXingFFI.read(image, return_errors: i.even?)
      GC.start if (i % 1000).zero?
    end
    GC.start
    growth_mb = (rss_kb - before) / 1024.0

    assert_operator growth_mb, :<, 20, "RSS grew by #{growth_mb.round(1)} MB over #{iterations} decodes"
  end

  # An interrupt arriving while the GVL-free decode runs is delivered only after the native results are freed
  # (found by the review: previously it fired between the native return and the assignment, leaking the result).
  def test_interrupt_during_decode_does_not_leak_the_native_result
    image = ZXingFFI::Image.new(Random.new(7).bytes(3000 * 3000), width: 3000, height: 3000)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    ZXingFFI.read(image)
    decode_time = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    skip "decode too fast (#{decode_time.round(3)} s) to interrupt reliably" if decode_time < 0.2

    deletes = 0
    original = ZXingFFI::Native.method(:ZXing_Barcodes_delete)
    ZXingFFI::Native.define_singleton_method(:ZXing_Barcodes_delete) do |pointer|
      deletes += 1
      original.call(pointer)
    end
    begin
      reader = Thread.new do
        Thread.current.report_on_exception = false # the RuntimeError below is expected
        ZXingFFI.read(image)
      end
      sleep decode_time / 3
      skip "decode finished before the interrupt" unless reader.alive?
      reader.raise(RuntimeError, "stop")
      assert_raises(RuntimeError) { reader.join }
      assert_equal 1, deletes, "the Barcodes collection must be deleted before the interrupt is delivered"
    ensure
      ZXingFFI::Native.define_singleton_method(:ZXing_Barcodes_delete, original)
    end
  end

  def test_many_images_can_be_released_deterministically
    200.times do
      image = IMAGES.qr_image(scale: 2)
      assert_equal 1, ZXingFFI.read(image).size
      image.release!
    end
  end

  private

  def rss_kb
    if File.readable?("/proc/self/status")
      File.read("/proc/self/status")[/^VmRSS:\s+(\d+)/, 1]&.to_i
    else
      out = IO.popen(["ps", "-o", "rss=", "-p", Process.pid.to_s], &:read)
      Integer(out.strip, exception: false)
    end
  end
end
