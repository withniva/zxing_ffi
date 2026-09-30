# frozen_string_literal: true

require "test_helper"
require "pathname"
require "stringio"

class SnifferTest < Minitest::Test
  Sniffer = ZXingFFI::Sniffer

  PNG = "\x89PNG\r\n\x1A\n\x00\x00\x00\x0DIHDR".b
  JPEG = "\xFF\xD8\xFF\xE0\x00\x10JFIF\x00".b
  PDF = "%PDF-1.7\n%\xE2\xE3\xCF\xD3\n1 0 obj\n".b

  def detect(bytes)
    Sniffer.detect(bytes.b)
  end

  # An ISO-BMFF ftyp box: size, "ftyp", major brand, minor version, compatible brands.
  def ftyp(major, *compatible, size: nil, trailer: "\x00\x00\x00\x08mdat")
    body = "ftyp#{major}\x00\x00\x00\x00#{compatible.join}"
    [size || body.bytesize + 4].pack("N") + body + trailer
  end

  # A BMP file header followed by the size field of a DIB header.
  def bmp(dib_size)
    "BM".b + [70, 0, 54, dib_size].pack("VVVV") + "\x00" * 16
  end

  # --- detect -------------------------------------------------------------------------------------------

  def test_constants
    assert_equal %i[pdf png jpeg tiff gif bmp webp heif avif pnm], Sniffer::KINDS
    assert_predicate Sniffer::KINDS, :frozen?
    assert_equal 1024, Sniffer::HEAD_SIZE
  end

  def test_png
    assert_equal :png, detect(PNG)
    assert_equal :png, detect("\x89PNG\r\n\x1A\n")
  end

  def test_jpeg
    assert_equal :jpeg, detect(JPEG)
    assert_equal :jpeg, detect("\xFF\xD8\xFF\xE1\x00\x16Exif")
    assert_equal :jpeg, detect("\xFF\xD8\xFF\xDB")
    assert_equal :jpeg, detect("\xFF\xD8\xFF")
  end

  def test_tiff_both_byte_orders_and_bigtiff
    ["II*\x00\x08\x00\x00\x00", "MM\x00*\x00\x00\x00\x08", "II+\x00\x08\x00\x00\x00", "MM\x00+\x00\x08\x00\x00"].each do |head|
      assert_equal :tiff, detect(head), head.inspect
    end
  end

  def test_gif
    assert_equal :gif, detect("GIF87a\x01\x00\x01\x00")
    assert_equal :gif, detect("GIF89a\x01\x00\x01\x00")
  end

  def test_bmp_with_every_known_dib_header_size
    [12, 16, 40, 52, 56, 64, 108, 124].each do |dib_size|
      assert_equal :bmp, detect(bmp(dib_size)), "DIB header size #{dib_size}"
    end
  end

  def test_bmp_false_positives
    assert_nil detect("BMW 3 Series owner's manual\n" * 3)
    assert_nil detect("BM this is plain text that happens to start with BM\n")
    [0, 1, 39, 41, 100, 125, 0xFFFFFFFF].each do |dib_size|
      assert_nil detect(bmp(dib_size)), "DIB header size #{dib_size}"
    end
  end

  def test_webp
    assert_equal :webp, detect("RIFF\x24\x00\x00\x00WEBPVP8 \x18\x00\x00\x00")
    assert_equal :webp, detect("RIFF\x00\x00\x00\x00WEBP")
  end

  def test_other_riff_containers_are_not_webp
    assert_nil detect("RIFF\x24\x08\x00\x00WAVEfmt \x10\x00\x00\x00")
    assert_nil detect("RIFF\x24\x08\x00\x00AVI LIST")
    assert_nil detect("RIFX\x24\x00\x00\x00WEBP")
  end

  def test_heif_major_brands
    %w[heic heix heim heis hevc hevx].each do |brand|
      assert_equal :heif, detect(ftyp(brand, "mif1", brand)), brand
    end
  end

  def test_avif_major_brands
    assert_equal :avif, detect(ftyp("avif", "avif", "mif1", "miaf", "MA1B"))
    assert_equal :avif, detect(ftyp("avis", "avis", "msf1", "miaf", "MA1B"))
  end

  def test_generic_heif_brands_depend_on_the_compatible_brands
    assert_equal :avif, detect(ftyp("mif1", "mif1", "avif", "miaf"))
    assert_equal :avif, detect(ftyp("msf1", "msf1", "avis"))
    assert_equal :heif, detect(ftyp("mif1", "mif1", "heic"))
    assert_equal :heif, detect(ftyp("msf1", "msf1", "hevc"))
    assert_equal :heif, detect(ftyp("mif1"))
  end

  def test_other_iso_bmff_files_are_not_images
    assert_nil detect(ftyp("isom", "isom", "iso2", "avc1", "mp41"))
    assert_nil detect(ftyp("mp42", "mp42", "isom"))
    assert_nil detect(ftyp("qt  ", "qt  "))
    assert_nil detect(ftyp("M4A ", "M4A ", "mp42", "isom"))
    assert_nil detect(ftyp("crx ", "crx "))
    # a compatible brand alone does not make an MP4 an image
    assert_nil detect(ftyp("isom", "avif", "heic"))
  end

  def test_ftyp_compatible_brands_are_read_only_inside_the_box
    # a 16-byte box holds no compatible brand; the "avif" after it belongs to the next box
    assert_equal :heif, detect(ftyp("mif1", size: 16, trailer: "avif\x00\x00\x00\x08mdat"))
    # the brand at bytes 16..19 counts only if the whole brand is inside the box
    assert_equal :heif, detect(ftyp("mif1", "avif", size: 19))
    assert_equal :avif, detect(ftyp("mif1", "avif", size: 20))
  end

  def test_ftyp_box_size_zero_extends_to_the_end
    assert_equal :avif, detect(ftyp("mif1", "miaf", "avif", size: 0, trailer: ""))
  end

  def test_ftyp_box_larger_than_the_head_is_capped
    head = ftyp("mif1", *(["miaf"] * 300), "avif", trailer: "")
    assert_operator head.bytesize, :>, Sniffer::HEAD_SIZE
    assert_equal :heif, detect(head), "avif lies beyond the first #{Sniffer::HEAD_SIZE} bytes"
    assert_equal :avif, detect(ftyp("mif1", *(["miaf"] * 200), "avif", trailer: ""))
  end

  def test_ftyp_invalid_box_sizes
    (1..15).each do |size|
      assert_nil detect(ftyp("heic", "mif1", size: size)), "size #{size}"
    end
    assert_equal :heif, detect(ftyp("heic", size: 16, trailer: ""))
  end

  def test_pnm_with_every_separator
    (1..6).each do |n|
      [" ", "\t", "\n", "\v", "\f", "\r", "#"].each do |separator|
        assert_equal :pnm, detect("P#{n}#{separator}"), "P#{n}#{separator.inspect}"
      end
    end
    assert_equal :pnm, detect("P5\n640 480\n255\n")
    assert_equal :pnm, detect("P4 # comment\n8 1\n\x00")
  end

  def test_pnm_needs_a_separator_and_a_supported_variant
    assert_nil detect("P5")
    assert_nil detect("P5x")
    assert_nil detect("P55 5 255\n")
    assert_nil detect("P7\nWIDTH 1\n")
    assert_nil detect("P0\n")
    assert_nil detect("PF\n1 1\n-1.0\n")
    assert_nil detect("p5\n1 1\n255\n")
  end

  def test_pdf
    assert_equal :pdf, detect(PDF)
    assert_equal :pdf, detect("%PDF-")
    assert_equal :pdf, detect("%PDF-2.0\n")
  end

  def test_pdf_after_leading_junk
    assert_equal :pdf, detect("\r\n#{PDF}")
    assert_equal :pdf, detect("garbage\x00\xFF\n".b * 20 + PDF)
    assert_equal :pdf, detect("GIF8" + PDF), "junk that looks like a truncated magic"
  end

  def test_pdf_marker_must_lie_within_the_first_1024_bytes
    assert_equal :pdf, detect("x" * 1019 + "%PDF-1.4"), "marker ends at byte 1024"
    assert_nil detect("x" * 1020 + "%PDF-1.4"), "marker crosses the 1024-byte boundary"
    assert_nil detect("x" * 1024 + "%PDF-1.4")
    assert_nil detect(" " * 5000 + PDF)
  end

  def test_offset_zero_signatures_win_over_an_embedded_pdf_marker
    assert_equal :jpeg, detect(JPEG + "%PDF-1.4")
    assert_equal :png, detect(PNG + "tEXt%PDF-")
    assert_equal :pnm, detect("P6\n# %PDF-1.4\n1 1 255\n")
  end

  def test_truncated_magics
    [
      "\x89PNG\r\n\x1A", "\x89PNG", "\x89", "\xFF\xD8", "\xFF", "II*", "MM\x00", "II", "GIF89", "GIF8", "GIF",
      "BM", "BM\x46\x00\x00\x00\x00\x00\x00\x00\x36\x00\x00\x00\x28\x00\x00", "RIFF\x24\x00\x00\x00WEB", "RIFF",
      "\x00\x00\x00\x18ftyphei", "\x00\x00\x00\x18ftyp", "%PDF", "%PD", "P", "P5"
    ].each do |head|
      assert_nil detect(head), head.inspect
    end
  end

  def test_near_misses
    ["\x89PNG\r\n\x1A\x00", "\x89PNX\r\n\x1A\n", "\xFF\xD9\xFF", "\xFF\xD8\x00", "II\x00*", "MM*\x00", "IIxx",
      "GIF88a", "GIF89b", "%!PS-Adobe-3.0", "%PDF 1.4", "%pdf-1.4"].each do |head|
      assert_nil detect(head), head.inspect
    end
  end

  def test_unrecognized_formats
    [
      "<!DOCTYPE html>\n<html>", "<?xml version=\"1.0\"?><svg xmlns=\"http://www.w3.org/2000/svg\"/>",
      "PK\x03\x04\x14\x00\x00\x00", "\x1F\x8B\x08\x00", "hello world", "\x00" * 64, "\x00\x00\x01\x00\x01\x00",
      "8BPS\x00\x01", "\x00\x00\x00\x0CjP  \r\n\x87\n", "\xFF\x0A"
    ].each do |head|
      assert_nil detect(head), head.inspect
    end
  end

  def test_empty_and_nil
    assert_nil Sniffer.detect("")
    assert_nil Sniffer.detect(nil)
  end

  def test_detect_rejects_non_strings
    assert_raises(TypeError) { Sniffer.detect(42) }
    assert_raises(TypeError) { Sniffer.detect(StringIO.new(PNG)) }
  end

  def test_detect_ignores_the_string_encoding
    utf8 = PNG.dup.force_encoding(Encoding::UTF_8)
    refute_predicate utf8, :valid_encoding?

    assert_equal :png, Sniffer.detect(utf8)
    assert_equal :pdf, Sniffer.detect("été %PDF-1.4")
    assert_equal :jpeg, Sniffer.detect(JPEG.dup.force_encoding(Encoding::UTF_16LE))
    assert_equal :avif, Sniffer.detect(ftyp("mif1", "avif").force_encoding(Encoding::UTF_8))
    assert_equal Encoding::UTF_8, utf8.encoding, "the argument must not be modified"
  end

  def test_detect_accepts_frozen_and_long_strings
    assert_equal :png, Sniffer.detect(PNG.dup.freeze)
    assert_equal :tiff, Sniffer.detect("II*\x00".b + Random.new(1).bytes(5_000_000))
  end

  # --- sniff: paths ---------------------------------------------------------------------------------------

  def test_sniff_string_and_pathname_paths
    in_tmpdir do |dir|
      path = File.join(dir, "no-extension")
      File.binwrite(path, PNG + "\x00" * 5000)

      assert_equal :png, Sniffer.sniff(path)
      assert_equal :png, Sniffer.sniff(Pathname.new(path))
    end
  end

  def test_sniff_ignores_the_file_extension
    in_tmpdir do |dir|
      path = File.join(dir, "actually-a-pdf.png")
      File.binwrite(path, PDF)

      assert_equal :pdf, Sniffer.sniff(path)
    end
  end

  def test_sniff_every_kind_from_files
    samples = {
      pdf: PDF, png: PNG, jpeg: JPEG, tiff: "MM\x00*\x00\x00\x00\x08".b, gif: "GIF89a\x01\x00".b, bmp: bmp(40),
      webp: "RIFF\x24\x00\x00\x00WEBPVP8L".b, heif: ftyp("heic", "mif1", "heic"), avif: ftyp("avif", "mif1"),
      pnm: "P5\n1 1\n255\n\x00".b
    }
    assert_equal Sniffer::KINDS.sort, samples.keys.sort

    in_tmpdir do |dir|
      samples.each do |kind, bytes|
        path = File.join(dir, "input-#{kind}")
        File.binwrite(path, bytes)
        assert_equal kind, Sniffer.sniff(path), kind.to_s
      end
    end
  end

  def test_sniff_missing_file
    in_tmpdir do |dir|
      assert_raises(Errno::ENOENT) { Sniffer.sniff(File.join(dir, "missing.pdf")) }
      assert_raises(Errno::ENOENT) { Sniffer.sniff(Pathname.new(dir).join("missing.png")) }
    end
  end

  def test_sniff_directory
    in_tmpdir do |dir|
      assert_raises(Errno::EISDIR) { Sniffer.sniff(dir) }
    end
  end

  def test_sniff_empty_file
    in_tmpdir do |dir|
      path = File.join(dir, "empty.pdf")
      File.binwrite(path, "")

      error = assert_raises(ZXingFFI::UnsupportedInput) { Sniffer.sniff(path) }
      assert_equal "empty input: #{path} contains no data", error.message
    end
  end

  def test_sniff_unrecognized_file_message
    in_tmpdir do |dir|
      path = File.join(dir, "page.pdf")
      File.binwrite(path, "<!DOCTYPE html>\n<html><body>Not found</body></html>\n")

      error = assert_raises(ZXingFFI::UnsupportedInput) { Sniffer.sniff(path) }
      assert_kind_of ZXingFFI::Error, error
      assert_includes error.message, path
      assert_includes error.message, "not a PDF, PNG, JPEG, TIFF, GIF, BMP, WebP, HEIF, AVIF or PNM file"
      assert_includes error.message, "first bytes: 3c 21 44 4f 43 54 59 50 45 20 68 74 6d 6c 3e 0a |<!DOCTYPE html>.|"
      assert_includes error.message, "detected from the content, not the file name"
    end
  end

  def test_hex_dump_is_short_and_escapes_binary
    error = assert_raises(ZXingFFI::UnsupportedInput) { Sniffer.sniff(StringIO.new("\x00\x01\x7F\x80\xFFabc".b * 10)) }

    assert_includes error.message, "(first bytes: 00 01 7f 80 ff 61 62 63 00 01 7f 80 ff 61 62 63 |.....abc.....abc|)"
  end

  def test_hex_dump_of_short_input
    error = assert_raises(ZXingFFI::UnsupportedInput) { Sniffer.sniff(StringIO.new("ab")) }

    assert_includes error.message, "(first bytes: 61 62 |ab|)"
  end

  def test_sniff_file_with_pdf_marker_beyond_the_head
    in_tmpdir do |dir|
      path = File.join(dir, "late.pdf")
      File.binwrite(path, " " * 2000 + PDF)

      assert_raises(ZXingFFI::UnsupportedInput) { Sniffer.sniff(path) }
    end
  end

  # --- sniff: IOs -----------------------------------------------------------------------------------------

  def test_sniff_stringio_restores_the_position
    io = StringIO.new(JPEG + "\x00" * 4000)

    assert_equal :jpeg, Sniffer.sniff(io)
    assert_equal 0, io.pos
  end

  def test_sniff_io_reads_from_the_current_position
    io = StringIO.new("junk!" + PNG)
    io.seek(5)

    assert_equal :png, Sniffer.sniff(io)
    assert_equal 5, io.pos
  end

  def test_sniff_file_io_restores_the_position
    in_tmpdir do |dir|
      path = File.join(dir, "doc")
      File.binwrite(path, PDF + "x" * 3000)

      File.open(path, "rb") do |file|
        assert_equal :pdf, Sniffer.sniff(file)
        assert_equal 0, file.pos
        assert_equal PDF, file.read(PDF.bytesize)
      end
    end
  end

  def test_sniff_unseekable_io_reads_at_most_head_size
    reader, writer = IO.pipe
    writer.write(PNG + "z" * (2000 - PNG.bytesize))
    writer.close

    assert_equal :png, Sniffer.sniff(reader)
    assert_equal 2000 - Sniffer::HEAD_SIZE, reader.read.bytesize
  ensure
    reader&.close
  end

  def test_sniff_empty_io
    error = assert_raises(ZXingFFI::UnsupportedInput) { Sniffer.sniff(StringIO.new) }
    assert_equal "empty input: StringIO contains no data", error.message

    io = StringIO.new(PNG)
    io.read
    assert_raises(ZXingFFI::UnsupportedInput) { Sniffer.sniff(io) }
    assert_equal PNG.bytesize, io.pos
  end

  def test_sniff_io_error_names_the_file
    in_tmpdir do |dir|
      path = File.join(dir, "notes.txt")
      File.binwrite(path, "just text")

      error = File.open(path, "rb") { |file| assert_raises(ZXingFFI::UnsupportedInput) { Sniffer.sniff(file) } }
      assert_includes error.message, path
    end
  end

  def test_sniff_restores_the_position_when_detection_fails
    io = StringIO.new("unknown format")
    io.seek(3)

    assert_raises(ZXingFFI::UnsupportedInput) { Sniffer.sniff(io) }
    assert_equal 3, io.pos
  end

  def test_sniff_rejects_other_types
    error = assert_raises(TypeError) { Sniffer.sniff(42) }
    assert_equal "expected a path (String or Pathname) or an IO, got Integer", error.message
    assert_raises(TypeError) { Sniffer.sniff(nil) }
  end
end
