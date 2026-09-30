# frozen_string_literal: true

require "test_helper"
require "json"
require "open3"
require "rbconfig"
require "stringio"

# zxing-scan: JSON Lines output, options, exit codes. Golden output: test/fixtures/cli/golden.jsonl.
class CLITest < Minitest::Test
  EXE = File.expand_path("../../exe/zxing-scan", __dir__)
  VECTOR_PDF = "test/fixtures/pdfs/vector_qr_code128_datamatrix.pdf"
  BINARY_QR = "test/fixtures/symbologies/qr_code_binary.pgm"

  def setup
    require_native!
    Dir.chdir(ZXingFFI::TestSupport::ROOT) # golden output records relative paths
  end

  def cli(*argv, env: {})
    out = StringIO.new
    err = StringIO.new
    status = ZXingFFI::CLI.new(argv, stdout: out, stderr: err, env: env).run
    [status, out.string, err.string]
  end

  def pdf_available?
    ZXingFFI::Loaders::PopplerLoader.available?
  end

  def test_golden_output
    require_tool!(:poppler) { pdf_available? }
    status, out, err = cli(VECTOR_PDF, BINARY_QR)

    assert_equal 0, status, err
    actual = out.lines.map { |line| JSON.parse(line) }
    golden = File.readlines(fixture_path("cli", "golden.jsonl"), encoding: "UTF-8").map { |line| JSON.parse(line) } # any locale
    assert_equal golden.size, actual.size
    golden.zip(actual).each do |want, got|
      assert_equal want.keys, got.keys, "field order"
      %w[file page format text bytes_b64 content_type rotation pass].each do |key|
        want[key].nil? ? assert_nil(got[key], key) : assert_equal(want[key], got[key], key)
      end
      %w[position page_position].each do |key|
        next assert_nil(got[key]) if want[key].nil?

        want[key].flatten.zip(got[key].flatten).each { |w, g| assert_in_delta w, g, (key == "position") ? 3 : 1, key }
      end
    end
  end

  def test_record_fields
    status, out, = cli(BINARY_QR)
    record = JSON.parse(out)

    assert_equal 0, status
    assert_equal %w[file page format text bytes_b64 content_type position page_position rotation pass], record.keys
    assert_equal "binary", record["content_type"]
    assert_equal "BIN\x00\x01\x7F\x80".b + "\xFE\xFF".b, record["bytes_b64"].unpack1("m0")
    assert_equal 4, record["position"].size
    assert_nil record["page_position"]
  end

  def test_text_content_has_no_bytes_field
    _, out, = cli("test/fixtures/symbologies/qr_code.pgm")
    refute JSON.parse(out).key?("bytes_b64")
  end

  def test_text_only
    status, out, = cli("--text-only", "test/fixtures/symbologies/qr_code.pgm", "test/fixtures/symbologies/code_128.pgm")
    assert_equal 0, status
    assert_equal 2, out.lines.size
    assert_equal "Hello, World!", out.lines.first.chomp
  end

  def test_no_barcodes_exits_1
    in_tmpdir do |dir|
      path = File.join(dir, "blank.pgm")
      File.binwrite(path, ZXingFFI::SyntheticImages.blank.to_pgm)
      status, out, = cli(path)
      assert_equal 1, status
      assert_empty out
    end
  end

  def test_processing_error_exits_3_but_other_files_are_scanned
    status, out, err = cli("/nonexistent/file.png", "test/fixtures/symbologies/qr_code.pgm")

    assert_equal 3, status
    assert_equal 1, out.lines.size
    assert_match(%r{zxing-scan: /nonexistent/file.png: ENOENT}, err)
  end

  # One file's problem (here: page 3 of a 1-page file) must not stop the batch (found by the review).
  def test_a_per_file_error_does_not_abort_the_batch
    require_tool!(:poppler) { pdf_available? }
    status, out, err = cli("--text-only", "-p", "3", "test/fixtures/pdfs/vector_qr_code128_datamatrix.pdf",
      "test/fixtures/pdfs/multipage_codes_p1_p3.pdf")

    assert_equal 3, status
    assert_match(/vector_qr_code128_datamatrix\.pdf: ArgumentError: no pages selected/, err)
    refute_empty out, "the second file must still be scanned"
  end

  # File names are bytes on Linux; JSON output must not crash on invalid UTF-8.
  def test_records_scrub_non_utf8_file_names
    barcode = ZXingFFI.read(ZXingFFI::SyntheticImages.qr_image).first.with(page: 1, pass: :base)
    record = ZXingFFI::CLI.new([]).record("scan-\xFF.png".b, barcode)

    assert_equal "scan-�.png", record[:file]
    JSON.generate(record)
  end

  def test_usage_errors_exit_2
    assert_equal 2, cli.first
    assert_equal 2, cli("--effort", "extreme", "x.png").first
    assert_equal 2, cli("--stop", "sometimes", "x.png").first
    assert_equal 2, cli("--dpi", "high", "x.png").first
    assert_equal 2, cli("--pages", "a-b", "x.png").first
    assert_equal 2, cli("--bogus").first
    assert_equal 2, cli("--formats", "not_a_format", "test/fixtures/symbologies/qr_code.pgm").first
  end

  def test_formats_filter
    status, out, = cli("--text-only", "-f", "code_128,ean_13", "test/fixtures/symbologies/qr_code.pgm")
    assert_equal 1, status
    assert_empty out
  end

  def test_pages_and_password
    require_tool!(:poppler) { pdf_available? }
    _, out, = cli("--text-only", "-p", "3", "test/fixtures/pdfs/multipage_codes_p1_p3.pdf")
    assert(out.lines.all? { |l| l.include?("3") }, out)

    status, _, err = cli("test/fixtures/pdfs/encrypted_aes256_user_password.pdf")
    assert_equal 3, status
    assert_match(/PasswordRequired/, err)
    assert_equal 0, cli("--password", "secret", "test/fixtures/pdfs/encrypted_aes256_user_password.pdf").first
    assert_equal 0, cli("test/fixtures/pdfs/encrypted_aes256_user_password.pdf", env: {"ZXING_PDF_PASSWORD" => "secret"}).first
  end

  def test_option_parsing
    parser_cli = ZXingFFI::CLI.new([])
    assert_equal [1, 2, 3, 7], parser_cli.send(:pages, "1-3,7")
    assert_equal (5..), parser_cli.send(:pages, "5-")
    assert_equal 3, parser_cli.send(:stop, "3")
    assert_equal :exhaustive, parser_cli.send(:stop, "exhaustive")
    assert_equal :auto, parser_cli.send(:dpi, "auto")
    assert_equal 150, parser_cli.send(:dpi, "150")
  end

  def test_diagnose
    status, out, = cli("--diagnose")
    diagnostics = JSON.parse(out)

    assert_equal 0, status
    assert diagnostics.dig("library", "loaded")
    assert diagnostics.key?("loaders")
    assert diagnostics.key?("transformers")
  end

  def test_executable
    env = {"ZXING_LIB" => ENV["ZXING_LIB"].to_s}
    out, err, status = Open3.capture3(env, RbConfig.ruby, "-I", File.join(ZXingFFI::TestSupport::ROOT, "lib"), EXE,
      "--text-only", "test/fixtures/symbologies/qr_code.pgm")
    assert status.success?, err
    assert_equal "Hello, World!\n", out

    _, _, version = Open3.capture3(env, RbConfig.ruby, "-I", File.join(ZXingFFI::TestSupport::ROOT, "lib"), EXE, "--version")
    assert version.success?
  end
end
