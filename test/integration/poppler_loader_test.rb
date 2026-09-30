# frozen_string_literal: true

require "test_helper"
require "yaml"

# PopplerLoader and PDF specifics against the generated PDF fixtures (test/fixtures/pdfs).
class PopplerLoaderTest < Minitest::Test
  LOADER = ZXingFFI::Loaders::PopplerLoader

  def setup
    require_tool!(:poppler) { LOADER.available? }
    require_native!
  end

  def pdf(name)
    path = fixture_path("pdfs", name)
    skip "missing fixture #{name} (script/generate_fixtures pdfs)" unless File.exist?(path)
    path
  end

  def open_pdf(name, config: ZXingFFI::Config.new, password: nil)
    ZXingFFI::Source.open(pdf(name)) do |source|
      document = LOADER.new(config).open(source, password: password)
      begin
        yield document
      ensure
        document.close
      end
    end
  end

  def test_availability_and_diagnostics
    diagnostics = LOADER.diagnostics
    assert diagnostics[:available]
    assert_match(/\A\d+\.\d+/, diagnostics[:version])
    assert diagnostics[:tools][:pdftoppm]
    assert_equal [:pdf], diagnostics[:kinds]
  end

  def test_missing_tools_make_the_loader_unavailable
    ZXingFFI.config.tool_paths[:pdftoppm] = "/nonexistent/pdftoppm"
    LOADER.reset!
    refute LOADER.available?
    assert_match(/pdftoppm not found/, LOADER.unavailable_reason)
    error = assert_raises(ZXingFFI::LoaderUnavailable) { ZXingFFI.scan(pdf("vector_qr_code128_datamatrix.pdf"), loader: :poppler) }
    assert_match(/poppler/, error.message)
  ensure
    ZXingFFI.reset_config!
    LOADER.reset!
  end

  def test_page_count_and_sizes
    open_pdf("multipage_codes_p1_p3.pdf") do |document|
      assert_equal 3, document.page_count
      info = document.page_info(2)
      assert_equal [612.0, 792.0, :pt, 0], [info.width, info.height, info.unit, info.rotation]
      assert_nil info.native_ppi
      assert_raises(ArgumentError) { document.page_info(4) }
    end
  end

  def test_rotated_pages_report_displayed_sizes
    open_pdf("rotate_mixed_pages.pdf") do |document|
      sizes = (1..4).map { |n| document.page_info(n).then { |i| [i.width, i.height, i.rotation] } }
      assert_equal [[612.0, 792.0, 0], [792.0, 612.0, 90], [595.28, 841.89, 180], [612.0, 792.0, 270]], sizes
      page = document.render(2, dpi: 72)
      assert_equal [792, 612], [page.image.width, page.image.height], "the base image is the page as displayed"
    end
  end

  def test_render_size_and_metadata
    open_pdf("vector_qr_code128_datamatrix.pdf") do |document|
      page = document.render(1, dpi: 100)
      assert_equal [850, 1100], [page.image.width, page.image.height]
      assert_equal 100, page.dpi
      assert_equal :lum, page.image.format
      assert_equal :poppler, page.metadata[:loader]
      refute_empty ZXingFFI.read(page.image)
      assert_equal [ZXingFFI::Config.new.default_dpi * 612 / 72], [document.render(1).image.width]
    end
  end

  def test_native_ppi_of_scanned_pages
    open_pdf("scanned_jpeg_200dpi.pdf") { |document| assert_equal 200.0, document.page_info(1).native_ppi }
    open_pdf("scanned_ccitt_g4_fax_204x98.pdf") { |document| assert_equal 204.0, document.page_info(1).native_ppi }
    open_pdf("embedded_png_codes.pdf") { |document| assert_nil document.page_info(1).native_ppi }
  end

  def test_encrypted_without_password
    error = assert_raises(ZXingFFI::PasswordRequired) { open_pdf("encrypted_aes256_user_password.pdf") { flunk } }
    refute_kind_of ZXingFFI::IncorrectPassword, error
  end

  def test_encrypted_with_wrong_password
    assert_raises(ZXingFFI::IncorrectPassword) { open_pdf("encrypted_aes256_user_password.pdf", password: "nope") { flunk } }
  end

  def test_encrypted_with_the_right_password
    open_pdf("encrypted_aes256_user_password.pdf", password: "secret") do |document|
      assert document.encrypted?
      refute_empty ZXingFFI.read(document.render(1, dpi: 150).image)
    end
  end

  def test_rc4_and_unicode_passwords
    %w[encrypted_rc4_128_user_password_supplied.pdf encrypted_aes256_unicode_password.pdf].each do |name|
      entry = manifest_entry(name)
      password = entry&.dig("options", "password") or skip("no password recorded for #{name}")
      open_pdf(name, password: password) { |document| assert_equal 1, document.page_count }
    end
  end

  def test_owner_password_only_opens_without_a_password
    open_pdf("encrypted_aes256_owner_password_only.pdf") do |document|
      assert document.encrypted?
      refute_empty ZXingFFI.read(document.render(1, dpi: 150).image)
    end
  end

  def test_password_is_passed_as_a_single_argument
    # A password that looks like options and shell syntax must be treated literally.
    assert_raises(ZXingFFI::IncorrectPassword) { open_pdf("encrypted_aes256_user_password.pdf", password: "-opw x; rm -rf / $(id)") { flunk } }
  end

  def test_max_pixels_is_checked_before_rendering
    open_pdf("vector_qr_code128_datamatrix.pdf", config: ZXingFFI::Config.new.with(max_pixels: 100_000)) do |document|
      error = assert_raises(ZXingFFI::LimitExceeded) { document.render(1, dpi: 300) }
      assert_equal :max_pixels, error.limit
      assert_equal 2550 * 3300, error.value
    end
  end

  def test_render_timeout_kills_the_renderer
    in_tmpdir do |dir|
      slow = File.join(dir, "pdftoppm")
      File.write(slow, "#!/bin/sh\nexec sleep 30\n")
      File.chmod(0o755, slow)
      config = ZXingFFI::Config.new.with(render_timeout: 0.3)
      config.tool_paths[:pdftoppm] = slow
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      open_pdf("vector_qr_code128_datamatrix.pdf", config: config) do |document|
        assert_raises(ZXingFFI::TimeoutError) { document.render(1, dpi: 72) }
      end
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 5, "the renderer must be killed, not awaited"
    end
  end

  def test_huge_declared_page_is_capped_by_the_scanner
    result = ZXingFFI.scan_pages(pdf("huge_page_14400pt.pdf"), loader: :poppler, effort: :fast).first

    assert result.metadata[:dpi_capped]
    assert_operator result.width * result.height, :<=, ZXingFFI.config.max_pixels
  end

  def test_corrupt_pdf_raises_render_error
    in_tmpdir do |dir|
      path = File.join(dir, "broken.pdf")
      File.binwrite(path, "%PDF-1.7\nthis is not a pdf\n%%EOF\n")
      assert_raises(ZXingFFI::RenderError) { ZXingFFI.scan(path, loader: :poppler) }
    end
  end

  # Tiny malformed PDFs used to escape as FloatDomainError / ArgumentError (found by the review).
  def test_malformed_page_sizes_raise_render_error
    in_tmpdir do |dir|
      ["0 0 0 792", "0 0 #{"9" * 400} 792"].each_with_index do |box, i|
        path = File.join(dir, "malformed#{i}.pdf")
        File.write(path, "%PDF-1.4\n1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj\n" \
          "2 0 obj << /Type /Pages /Kids [3 0 R] /Count 1 >> endobj\n" \
          "3 0 obj << /Type /Page /Parent 2 0 R /MediaBox [#{box}] >> endobj\ntrailer << /Root 1 0 R >>\n%%EOF\n")
        error = assert_raises(ZXingFFI::RenderError, box[0, 20]) { ZXingFFI.scan(path, loader: :poppler, effort: :thorough) }
        assert_match(/unusable size/, error.message)
      end
    end
  end

  # pdftoppm and pdfinfo keep at most 32 bytes of a password (found by the review).
  def test_passwords_longer_than_poppler_accepts
    error = assert_raises(ZXingFFI::NotSupported) { open_pdf("encrypted_aes256_user_password.pdf", password: "x" * 33) { flunk } }
    assert_match(/32 bytes/, error.message)
    assert_raises(ZXingFFI::IncorrectPassword) { open_pdf("encrypted_aes256_user_password.pdf", password: "x" * 32) { flunk } }
  end

  def test_concurrent_renders
    open_pdf("multipage_codes_p1_p3.pdf") do |document|
      sizes = Array.new(3) { |i| Thread.new { document.render(i + 1, dpi: 72).image.width } }.map(&:value)
      assert_equal [612, 612, 612], sizes
    end
  end

  def test_scan_multipage_with_page_selection_and_threads
    path = pdf("multipage_codes_p1_p3.pdf")
    serial = ZXingFFI.scan(path, loader: :poppler).map { |b| [b.page, b.text] }
    threaded = ZXingFFI.scan(path, loader: :poppler, threads: 3).map { |b| [b.page, b.text] }

    assert_equal serial, threaded
    assert_equal [1, 3], serial.map(&:first).uniq
    assert_equal serial.select { |page, _| page == 3 }, ZXingFFI.scan(path, loader: :poppler, pages: [3]).map { |b| [b.page, b.text] }
  end

  # A tile boundary can cut a wide PDF417 so that the left part still decodes; that partial read must be merged
  # with the full symbol. Found by the PDF fixture agent on these two pages at :thorough.
  def test_thorough_scans_do_not_duplicate_partially_read_symbols
    %w[embedded_png_codes.pdf scanned_ccitt_g4_300dpi.pdf].each do |name|
      barcodes = ZXingFFI.scan(pdf(name), effort: :thorough, stop: :exhaustive)
      counts = barcodes.map { |b| [b.page, b.format, b.text] }.tally
      assert_empty counts.select { |_, n| n > 1 }, "#{name}: #{barcodes.map { |b| [b.format, b.pass, b.center.to_a.map(&:round)] }}"
      assert_includes barcodes.map(&:format), :pdf417
    end
  end

  def test_page_positions_are_in_points_of_the_displayed_page
    barcodes = ZXingFFI.scan(pdf("vector_qr_code128_datamatrix.pdf"), dpi: 150)
    at_150 = barcodes.map { |b| [b.text, b.page_position.center] }
    at_300 = ZXingFFI.scan(pdf("vector_qr_code128_datamatrix.pdf"), dpi: 300).map { |b| [b.text, b.page_position.center] }

    assert_equal at_150.map(&:first), at_300.map(&:first)
    at_150.zip(at_300).each do |(_, low), (_, high)|
      assert_in_delta low.x, high.x, 1.5
      assert_in_delta low.y, high.y, 1.5
    end
    assert barcodes.all? { |b| b.dpi == 150 }
  end

  private

  def manifest_entry(name)
    fragment = fixture_path("manifest.d", "pdfs.yml")
    return nil unless File.exist?(fragment)

    YAML.safe_load_file(fragment, aliases: true).find { |e| e["file"] == "pdfs/#{name}" }
  end
end
