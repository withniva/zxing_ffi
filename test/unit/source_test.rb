# frozen_string_literal: true

require "test_helper"
require "pathname"
require "stringio"

# Inputs are paths or IOs, identified by magic bytes; IOs are spooled to a private temp file.
class SourceTest < Minitest::Test
  PGM = "P5\n2 2\n255\n\x00\xFF\xFF\x00".b

  def setup
    @dir = Dir.mktmpdir("zxing_source")
    @path = File.join(@dir, "image.data") # extension deliberately meaningless
    File.binwrite(@path, PGM)
  end

  def teardown
    FileUtils.rm_rf(@dir)
    super
  end

  def test_string_paths_are_used_in_place_and_made_absolute
    Dir.chdir(@dir) do
      ZXingFFI::Source.open("image.data") do |source|
        assert_equal File.realpath(@path), File.realpath(source.path)
        assert_equal :pnm, source.kind
        assert_equal "image.data", source.name
        assert source.path.start_with?("/")
      end
    end
  end

  # Pathname responds to #read, so it used to be spooled like an IO (found by the review).
  def test_pathnames_are_used_in_place
    ZXingFFI::Source.open(Pathname(@path)) do |source|
      assert_equal @path, source.path
      assert_equal :pnm, source.kind
    end
  end

  def test_ios_are_spooled_to_a_private_temp_file_that_is_removed
    spooled = nil
    ZXingFFI::Source.open(StringIO.new(PGM)) do |source|
      spooled = source.path
      refute_equal @path, spooled
      assert_equal PGM, File.binread(spooled)
      assert_equal 0o600, File.stat(spooled).mode & 0o777
      assert_equal :pnm, source.kind
    end
    refute File.exist?(spooled)
  end

  def test_temp_file_is_removed_when_the_block_raises
    spooled = nil
    assert_raises(RuntimeError) do
      ZXingFFI::Source.open(StringIO.new(PGM)) do |source|
        spooled = source.path
        raise "boom"
      end
    end
    refute File.exist?(spooled)
  end

  def test_ios_are_read_from_their_current_position
    io = StringIO.new("junk".b + PGM)
    io.read(4)
    ZXingFFI::Source.open(io) { |source| assert_equal PGM, File.binread(source.path) }
  end

  def test_non_regular_files_are_refused
    assert_raises(Errno::ENOENT) { ZXingFFI::Source.open(@dir) { flunk } }
    assert_raises(Errno::ENOENT) { ZXingFFI::Source.open(File.join(@dir, "missing.png")) { flunk } }
    fifo = File.join(@dir, "pipe")
    File.mkfifo(fifo)
    assert_raises(Errno::ENOENT) { ZXingFFI::Source.open(Pathname(fifo)) { flunk } }
  end

  def test_unknown_content_and_objects
    text = File.join(@dir, "notes.png")
    File.write(text, "not an image at all")
    assert_raises(ZXingFFI::UnsupportedInput) { ZXingFFI::Source.open(text) { flunk } }
    assert_raises(ZXingFFI::UnsupportedInput) { ZXingFFI::Source.open(42) { flunk } }
  end
end
