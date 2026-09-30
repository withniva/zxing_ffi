# frozen_string_literal: true

require "test_helper"

# PnmLoader: header and page info, streamed rendering, max_pixels checked before the raster, bounded
# reads. Pure Ruby plus FFI memory for the Image: no libZXing needed.
class PnmLoaderTest < Minitest::Test
  LOADER = ZXingFFI::Loaders::PnmLoader

  def setup
    @dir = Dir.mktmpdir("zxing_pnm_loader")
  end

  def teardown
    FileUtils.rm_rf(@dir)
    super
  end

  def write(name, bytes)
    path = File.join(@dir, name)
    File.binwrite(path, bytes)
    path
  end

  def open_document(path, **config)
    LOADER.new(ZXingFFI::Config.new.with(**config)).open(ZXingFFI::Source.new(path, :pnm))
  end

  # --- Header and page info ----------------------------------------------------------------------------------

  def test_header_and_page_info
    document = open_document(write("a.pgm", "P5\n# made by a test\n4 3\n255\n".b + (1..12).to_a.pack("C*")))

    assert_equal 1, document.page_count
    assert_equal ZXingFFI::Loaders::PageInfo.new(number: 1, width: 4, height: 3, unit: :px, rotation: 0, native_ppi: nil),
      document.page_info(1)
    assert_raises(ArgumentError) { document.page_info(2) }
    assert_raises(ArgumentError) { document.render(0) }
  end

  def test_header_with_comments_longer_than_the_first_read
    comment = "# #{"x" * 10_000}\n"
    document = open_document(write("long.pgm", "P5\n#{comment}3 1\n#{comment}255\n".b + "\x01\x02\x03".b))

    assert_equal [3, 1], document.page_info(1).to_h.values_at(:width, :height)
    assert_equal [1, 2, 3], document.render(1).image.to_bytes.bytes
  end

  def test_header_up_to_the_limit_is_accepted_and_longer_ones_are_rejected
    limit = LOADER::HEADER_LIMIT
    header = ->(comment_bytes) { "P5\n##{"x" * comment_bytes}\n3 1\n255\n".b }
    assert_equal limit, header.call(limit - 13).bytesize

    document = open_document(write("at_limit.pgm", header.call(limit - 13) + "\x01\x02\x03".b))
    assert_equal [1, 2, 3], document.render(1).image.to_bytes.bytes

    error = assert_raises(ZXingFFI::UnsupportedInput) { open_document(write("past_limit.pgm", header.call(limit - 12) + "\x01\x02\x03".b)) }
    assert_equal "PNM header longer than #{limit} bytes (long comments?) is not supported", error.message
  end

  # Found by a code review: a header that did not fit the first 4 KiB made the loader read the whole
  # file, so a comment running into a 1 GiB sparse tail cost 1 GiB of memory.
  def test_a_comment_that_never_ends_is_rejected_after_reading_the_limit
    skip "measuring object sizes needs CRuby" unless RUBY_ENGINE == "ruby"

    path = write("endless_comment.pgm", "P5\n# ".b)
    File.truncate(path, 2**30)
    error, largest = forbidding_whole_file_reads do
      largest_string { assert_raises(ZXingFFI::UnsupportedInput) { open_document(path) } }
    end

    assert_equal "PNM header longer than #{LOADER::HEADER_LIMIT} bytes (long comments?) is not supported", error.message
    assert_operator largest, :<=, 4 * LOADER::HEADER_LIMIT, "opening created a #{largest}-byte String"
  end

  def test_malformed_and_truncated_headers_keep_their_messages
    error = assert_raises(ZXingFFI::UnsupportedInput) { open_document(write("bad.pgm", "P5 abc\n".b + "\x00".b * 2_000_000)) }
    assert_match(/\Amalformed PNM header: expected width, got "abc\\n/, error.message)
    error = assert_raises(ZXingFFI::UnsupportedInput) { open_document(write("short.pgm", "P5 40")) }
    assert_equal "truncated PNM header: missing height", error.message
    error = assert_raises(ZXingFFI::UnsupportedInput) { open_document(write("empty.pgm", "")) }
    assert_equal "not a PNM image: no data", error.message
  end

  # --- Rendering ------------------------------------------------------------------------------------------------

  def test_render_p5
    pixels = Random.new(1).bytes(300 * 200)
    document = open_document(write("a.pgm", "P5 300 200 255\n".b + pixels))
    page = document.render(1)

    assert_equal pixels, page.image.to_bytes
    assert_equal [300, 200, :lum], [page.image.width, page.image.height, page.image.format]
    assert_equal [1, nil, 1.0], [page.number, page.dpi, page.scale_to_base]
    assert_equal({loader: :pnm, pnm_kind: :p5}, page.metadata)
    assert_equal pixels, document.render(1).image.to_bytes, "rendering again reads the file again"
  end

  def test_render_ascii
    page = open_document(write("a.pgm", "P2\n3 2\n15\n0 1 2\n13 14 # a comment\n 15\n")).render(1)
    assert_equal [0, 17, 34, 221, 238, 255], page.image.to_bytes.bytes
    assert_equal :p2, page.metadata[:pnm_kind]

    page = open_document(write("a.pbm", "P1\n4 2\n0 1 0 1\n1 0 1 0\n")).render(1)
    assert_equal [255, 0, 255, 0, 0, 255, 0, 255], page.image.to_bytes.bytes
  end

  def test_limit_exceeded_is_raised_from_the_header_before_the_raster_is_read
    # No raster at all: the limit must win over "truncated", whatever the header's length.
    ["P5\n40000 30000\n255\n", "P5\n# #{"x" * 10_000}\n40000 30000\n255\n"].each do |data|
      document = open_document(write("big.pgm", data.b), max_pixels: 64_000_000)
      assert_equal 40_000, document.page_info(1).width

      error = assert_raises(ZXingFFI::LimitExceeded) { document.render(1) }
      assert_equal [:max_pixels, 1_200_000_000], [error.limit, error.value]
      assert_equal "40000x30000 (1200000000 pixels) exceeds max_pixels 64000000", error.message
    end
    assert_equal 12, open_document(write("small.pgm", "P5 4 3 255\n".b + "\x00".b * 12), max_pixels: 12).render(1).image.bytesize
  end

  def test_truncated_raster
    document = open_document(write("short.pgm", "P5 40 40 255\n".b + "\x00".b * 100))
    error = assert_raises(ZXingFFI::UnsupportedInput) { document.render(1) }
    assert_equal "truncated PNM: expected 1600 bytes of pixel data, got 100", error.message

    document = open_document(write("short.ppm", "P3 2 2 255\n1 2 3 4 5 6\n"))
    error = assert_raises(ZXingFFI::UnsupportedInput) { document.render(1) }
    assert_equal "truncated PNM: expected 12 samples of pixel data, got 6", error.message
  end

  # --- Bounded reads (found by a code review) -------------------------------------------------------------------

  # A 40x40 image followed by a 1 GiB hole, which a sparse file makes cheap to create: rendering it read the
  # whole file (File.binread) and so cost 1 GiB of memory.
  def test_render_does_not_read_a_huge_tail
    skip "measuring object sizes needs CRuby" unless RUBY_ENGINE == "ruby"

    pixels = Random.new(2).bytes(1600)
    {
      "P5" => ["P5 40 40 255\n".b + pixels, pixels.bytes],
      "P2" => ["P2 40 40 255\n" + pixels.bytes.join(" ") + "\n", pixels.bytes]
    }.each do |name, (data, expected)|
      path = write("tail.pnm", data)
      File.truncate(path, data.bytesize + 2**30)
      document = open_document(path)

      page, largest = forbidding_whole_file_reads { largest_string { document.render(1) } }
      assert_equal expected, page.image.to_bytes.bytes, name
      assert_operator largest, :<=, 1024 * 1024, "#{name}: rendering created a #{largest}-byte String"
    end
  end

  private

  # Makes File.binread and File.read fail while the block runs, so that reading a whole sparse file fails the
  # test at once instead of allocating its tail.
  def forbidding_whole_file_reads
    %i[binread read].each do |name|
      File.define_singleton_method(name) { |*| raise Minitest::Assertion, "File.#{name} reads the whole file" }
    end
    yield
  ensure
    %i[binread read].each { |name| File.singleton_class.remove_method(name) if File.singleton_class.method_defined?(name, false) }
  end

  # The block's result and the size of the largest String any method returned while it ran.
  def largest_string
    require "objspace"
    largest = 0
    trace = TracePoint.new(:c_return, :return) do |point|
      value = point.return_value
      largest = [largest, ObjectSpace.memsize_of(value)].max if value.is_a?(String)
    end
    [trace.enable { yield }, largest]
  end
end
