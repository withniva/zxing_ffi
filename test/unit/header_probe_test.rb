# frozen_string_literal: true

require "test_helper"
require "zlib"

# Dimensions from headers before any decoding (PNG, GIF, BMP, PNM, JPEG).
class HeaderProbeTest < Minitest::Test
  PROBE = ZXingFFI::HeaderProbe

  def write(name, bytes)
    path = File.join(@dir, name)
    File.binwrite(path, bytes)
    path
  end

  def setup
    @dir = Dir.mktmpdir("zxing_probe")
  end

  def teardown
    FileUtils.rm_rf(@dir)
    super
  end

  def png_header(width, height)
    ihdr = [width, height, 8, 0, 0, 0, 0].pack("NNC5")
    "\x89PNG\r\n\x1a\n".b + [13].pack("N") + "IHDR" + ihdr + [Zlib.crc32("IHDR" + ihdr)].pack("N")
  end

  def test_png
    assert_equal [50_000, 40_000], PROBE.dimensions(write("a.png", png_header(50_000, 40_000)), :png)
    assert_nil PROBE.dimensions(write("b.png", "\x89PNG\r\n\x1a\n".b + "garbage-without-ihdr!!"), :png)
  end

  def test_gif
    assert_equal [30_000, 20_000], PROBE.dimensions(write("a.gif", "GIF89a".b + [30_000, 20_000].pack("v2") + "\x00\x00\x00".b), :gif)
    assert_nil PROBE.dimensions(write("b.gif", "GIF89a".b + [0, 10].pack("v2")), :gif)
  end

  def test_bmp_info_header_and_top_down_height
    bmp = "BM".b + ("\x00" * 12).b + [40, 30_000, -20_000].pack("Vl<l<") + ("\x00" * 8).b
    assert_equal [30_000, 20_000], PROBE.dimensions(write("a.bmp", bmp), :bmp)
  end

  def test_bmp_core_header
    bmp = "BM".b + ("\x00" * 12).b + [12, 640, 480].pack("Vvv") + ("\x00" * 8).b
    assert_equal [640, 480], PROBE.dimensions(write("core.bmp", bmp), :bmp)
  end

  def test_pnm
    assert_equal [50_000, 50_000], PROBE.dimensions(write("a.pgm", "P5\n# huge\n50000 50000\n255\n".b), :pnm)
    assert_nil PROBE.dimensions(write("b.pgm", "P5\n50000".b), :pnm)
  end

  # A JPEG marker segment: FF, marker, big-endian length (including itself), data.
  def segment(marker, data)
    [0xFF, marker, data.bytesize + 2].pack("CCn") + data.b
  end

  def sof(marker, width, height)
    segment(marker, [8, height, width, 1, 1, 0x11, 0].pack("Cn2C4"))
  end

  def test_jpeg_frame_header_after_segments_longer_than_the_head
    jpeg = "\xFF\xD8".b + segment(0xE0, "JFIF\x00\x01\x02".b) + segment(0xE1, "Exif\x00\x00" + ("x" * 65_000)) +
      segment(0xE2, "ICC_PROFILE\x00" + ("y" * 30_000)) + segment(0xDB, "\x00" * 65) + segment(0xC4, "\x00" * 30) +
      "\xFF\xFF".b + sof(0xC2, 5678, 1234) + segment(0xDA, "\x00" * 10)
    assert_operator jpeg.index("\xFF\xC2".b), :>, PROBE::HEAD_SIZE

    assert_equal [5678, 1234], PROBE.dimensions(write("progressive.jpg", jpeg), :jpeg)
  end

  def test_jpeg_markers_without_length_and_every_frame_type
    %w[C0 C1 C2 C3 C5 C6 C7 C9 CA CB CD CE CF].each do |hex|
      jpeg = "\xFF\xD8\xFF\x01\xFF\xD0".b + sof(hex.hex, 300, 200)
      assert_equal [300, 200], PROBE.dimensions(write("sof#{hex}.jpg", jpeg), :jpeg), "SOF #{hex}"
    end
  end

  def test_jpeg_without_a_usable_frame_header
    start = "\xFF\xD8".b
    {
      "sos_first" => start + segment(0xDA, "\x00" * 10) + sof(0xC0, 10, 10),
      "dht_only" => start + segment(0xC4, [0, 60_000, 60_000].pack("Cn2")), # DHT is not a frame header
      "height_zero" => start + sof(0xC0, 100, 0), # height defined later by a DNL marker
      "truncated_sof" => start + sof(0xC0, 100, 100)[0, 6],
      "truncated_segment" => start + segment(0xE1, "x" * 100)[0, 50],
      "bad_length" => start + "\xFF\xE0\x00\x01".b,
      "not_a_marker" => start + "\x00\x11".b,
      "eoi" => start + "\xFF\xD9".b
    }.each do |name, jpeg|
      assert_nil PROBE.dimensions(write("#{name}.jpg", jpeg), :jpeg), name
    end
  end

  def test_jpeg_bomb_fixture
    path = fixture_path("images", "limits_jpeg_60000x60000.jpg")
    assert_equal [60_000, 60_000], PROBE.dimensions(path, :jpeg)
    assert_raises(ZXingFFI::LimitExceeded) { PROBE.check!(path, :jpeg, 64_000_000) }
  end

  def test_other_kinds_and_unreadable_files_return_nil
    assert_nil PROBE.dimensions(write("a.jpg", "\xFF\xD8\xFF\xE0".b), :jpeg)
    assert_nil PROBE.dimensions(write("empty.png", ""), :png)
    assert_nil PROBE.dimensions(File.join(@dir, "missing.png"), :png)
  end

  def test_check_raises_limit_exceeded
    path = write("big.png", png_header(10_000, 10_000))
    error = assert_raises(ZXingFFI::LimitExceeded) { PROBE.check!(path, :png, 64_000_000) }

    assert_equal :max_pixels, error.limit
    assert_equal 100_000_000, error.value
    assert_nil PROBE.check!(path, :png, 100_000_000)
    assert_nil PROBE.check!(path, :png, nil)
    assert_nil PROBE.check!(write("x.jpg", "\xFF\xD8\xFF".b), :jpeg, 1)
  end

  def test_scanner_rejects_a_declared_bomb_before_any_loader_runs
    path = write("bomb.png", png_header(9_000, 9_000) + ("\x00" * 64).b)
    error = assert_raises(ZXingFFI::LimitExceeded) { ZXingFFI.scan(path, loader: :pnm) } # PnmLoader can't even read PNG
    assert_equal 81_000_000, error.value
  end
end
