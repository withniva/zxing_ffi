# frozen_string_literal: true

require "test_helper"
require "digest"
require "yaml"

# Golden corpus: every manifest entry is found at its declared effort level, at the expected
# position (within the entry's tolerance) and rotation, without duplicates; no-barcode pages yield nothing; error
# fixtures raise. Entries with `expected: null` are skipped. A local real-document corpus built by
# script/real_corpus (tmp/real_corpus/, never committed — it holds personal data) is included when present.
class CorpusManifestTest < Minitest::Test
  FIXTURES = ZXingFFI::TestSupport::FIXTURES
  LOCAL_REAL = File.join(ZXingFFI::TestSupport::ROOT, "tmp", "real_corpus")

  # Manifest entries plus "_root" (directory their "file" is relative to) and "_label" (test name prefix).
  def self.entries
    merged = File.join(FIXTURES, "manifest.yml")
    files = File.exist?(merged) ? [merged] : Dir[File.join(FIXTURES, "manifest.d", "*.yml")].sort
    committed = files.flat_map { |file| Array(YAML.safe_load_file(file, aliases: true)) }
      .map { |entry| entry.merge("_root" => FIXTURES, "_label" => "") }
    local_manifest = File.join(LOCAL_REAL, "manifest.yml")
    local = File.exist?(local_manifest) ? Array(YAML.safe_load_file(local_manifest, aliases: true)) : []
    committed + local.map { |entry| entry.merge("_root" => LOCAL_REAL, "_label" => "local_real_") }
  end

  # Capabilities a manifest entry may require beyond "some loader reads this kind".
  def self.capability?(name)
    case name.to_s
    when "heif", "avif" then ZXingFFI::Loaders::Registry.loader_for(name.to_sym) && true
    when "vips" then ZXingFFI::Loaders::VipsLoader.available?
    when "image_magick" then ZXingFFI::Loaders::ImageMagickLoader.available?
    when "poppler" then ZXingFFI::Loaders::PopplerLoader.available?
    when "transformer" then !ZXingFFI::Transformers.first_available.nil? # rotated_45 / raster high_res passes
    else true # e.g. jbig2: decoding is Poppler's job once the fixture exists
    end
  rescue ZXingFFI::LoaderUnavailable
    false
  end

  entries.each do |entry|
    name = entry["_label"] + entry.fetch("file").gsub(/[^a-z0-9]+/i, "_")

    define_method(:"test_#{name}") do
      require_native!
      path = File.join(entry["_root"], entry.fetch("file"))
      skip "fixture file missing: #{entry["file"]}" unless File.exist?(path)
      skip "expectations not recorded yet (#{entry["notes"]&.slice(0, 60)})" if entry["expected"].nil? && entry["expect_error"].nil?
      missing = Array(entry["requires"]).reject { |cap| self.class.capability?(cap) }
      missing.each { |cap| require_tool!(cap) { false } if ZXingFFI::Loaders::NAMES.key?(cap.to_sym) } # flunks if promised
      skip "requires #{missing.join(", ")}" if missing.any?
      kind = ZXingFFI::Sniffer.sniff(path)
      begin
        ZXingFFI::Loaders::Registry.loader_for(kind)
      rescue ZXingFFI::LoaderUnavailable => e
        # A loader promised by ZXING_EXPECT_TOOLS (CI loader variants) that reads this kind but is missing fails
        # instead of silently skipping the entry (found by the review). A present loader that refuses the kind by
        # configuration (vips and PDF) still skips.
        ZXingFFI::Loaders.registry.each do |name, klass|
          require_tool!(name) { klass.available? } if klass.kinds.include?(kind) && ZXingFFI::TestSupport.expected_tools.include?(name)
        end
        skip e.message.lines.first
      end

      options = symbolize(entry["options"] || {})
      if (error = entry["expect_error"])
        assert_raises(ZXingFFI.const_get(error)) { ZXingFFI.scan(path, **options) }
      else
        check_entry(entry, path, options)
      end
    end
  end

  private

  def check_entry(entry, path, options)
    effort = (entry["effort"] || "normal").to_sym
    barcodes = ZXingFFI.scan(path, effort: effort, stop: :exhaustive, **options)
    expected = Array(entry["expected"])
    label = "#{entry["file"]} at effort #{effort}"

    if expected.empty?
      assert_empty barcodes.map { |b| [b.format, b.text] }, "#{label}: false positives"
      return
    end

    # real documents identify codes by text_sha256 instead of text (they contain personal data)
    expected.group_by { |e| [e.fetch("page", 1), e["text"] || e.fetch("text_sha256")] }.each do |(page, text), wanted|
      by_digest = wanted.first.key?("text_sha256") && !wanted.first.key?("text")
      found = barcodes.select { |b| b.page == page && (by_digest ? Digest::SHA256.hexdigest(b.text) : b.text) == text }
      text = "sha256:#{text[0, 12]}…" if by_digest
      assert_equal wanted.size, found.size,
        "#{label}: expected #{wanted.size} × #{text.inspect} on page #{page}, found #{found.size} (all: #{summary(barcodes)})"

      wanted.each do |want|
        barcode = closest(found, want)
        assert_equal want["format"].to_sym, barcode.format, "#{label}: format of #{text.inspect}" if want["format"]
        if want["center"]
          center = (entry["kind"] == "pdf") ? barcode.page_position.center : barcode.center
          tolerance = want["tolerance"] || 5
          assert_in_delta want["center"][0], center.x, tolerance, "#{label}: x of #{text.inspect}"
          assert_in_delta want["center"][1], center.y, tolerance, "#{label}: y of #{text.inspect}"
        end
        if want["rotation"]
          delta = ((barcode.rotation - want["rotation"] + 180) % 360) - 180
          assert_operator delta.abs, :<=, 6, "#{label}: rotation of #{text.inspect} is #{barcode.rotation}, expected #{want["rotation"]}"
        end
      end
    end
  end

  def closest(found, want)
    return found.first unless want["center"] && found.size > 1

    found.min_by do |b|
      center = b.page_position ? b.page_position.center : b.center
      (center.x - want["center"][0])**2 + (center.y - want["center"][1])**2
    end
  end

  def summary(barcodes)
    barcodes.map { |b| "p#{b.page} #{b.format} #{b.text.inspect} (#{b.pass})" }.join(", ")
  end

  def symbolize(options)
    options.to_h do |key, value|
      value = value.to_sym if value.is_a?(String) && %w[effort stop text_mode binarizer ean_add_on loader on_page_error].include?(key.to_s)
      [key.to_sym, value]
    end
  end
end
