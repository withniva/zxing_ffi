# frozen_string_literal: true

require "test_helper"
require "etc"

# Concurrent decoding and GVL release.
class ConcurrencyTest < Minitest::Test
  IMAGES = ZXingFFI::SyntheticImages

  def setup
    require_native!
  end

  def test_threads_produce_the_same_results_as_serial
    images = [
      IMAGES.qr_image,
      IMAGES.qr_image(scale: 3, invert: true, canvas: [140, 140]),
      IMAGES.qr_image(canvas: [300, 200], offset: [50, 40]),
      IMAGES.blank
    ]
    serial = images.map { |image| signature(ZXingFFI.read(image)) }

    threads = Array.new(8) do |t|
      Thread.new do
        Array.new(100) do |i|
          index = (t + i) % images.size
          [index, signature(ZXingFFI.read(images[index]))]
        end
      end
    end
    threads.flat_map(&:value).each do |index, result|
      assert_equal serial[index], result
    end
  end

  def test_each_thread_can_use_its_own_options
    image = IMAGES.qr_image
    threads = Array.new(6) do |t|
      Thread.new do
        mode = t.even? ? :plain : :hex
        Array.new(50) { ZXingFFI.read(image, text_mode: mode).first.text }.uniq
      end
    end
    values = threads.map(&:value)

    values.each_with_index do |texts, t|
      assert_equal 1, texts.size
      assert_equal t.even? ? IMAGES::QR_TEXT : IMAGES::QR_TEXT.unpack1("H*").upcase.scan(/../).join(" "), texts.first
    end
  end

  # While one thread is inside ZXing_ReadBarcodes, other threads must keep running, so two threads decoding at once
  # finish in about the time of one decode. A binding that held the GVL (no `blocking: true`) would run them one
  # after the other: twice as long. (The previous version counted a spinning thread's progress, but most of that
  # happened outside the decode, so it also passed with the GVL held — found by the review.)
  def test_decode_releases_the_gvl
    skip "needs at least 2 CPUs to run two decodes at once" if Etc.nprocessors < 2

    noise = Random.new(42).bytes(2400 * 2400)
    image = ZXingFFI::Image.new(noise, width: 2400, height: 2400)
    decode = -> { ZXingFFI.read(image, formats: :all) }
    decode.call # warm-up
    single = fastest_of(3) { decode.call }
    skip "decode too fast (#{single.round(3)} s) to measure reliably" if single < 0.05

    pair = fastest_of(3) { Array.new(2) { Thread.new(&decode) }.each(&:join) }
    assert_operator pair, :<, 1.5 * single,
      "two concurrent decodes took #{pair.round(3)} s, one alone #{single.round(3)} s: they did not run in parallel"
  end

  private

  # Shortest wall time of +runs+ calls to the block (the minimum is the least noisy estimate).
  def fastest_of(runs)
    Array.new(runs) do
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      yield
      Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    end.min
  end

  def signature(barcodes)
    barcodes.map { |b| [b.text, b.format, b.position.to_a.map(&:to_a), b.rotation, b.inverted?] }
  end
end
