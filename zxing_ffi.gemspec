# frozen_string_literal: true

require_relative "lib/zxing_ffi/version"

Gem::Specification.new do |spec|
  spec.name = "zxing_ffi"
  spec.version = ZXingFFI::VERSION
  spec.authors = ["Will Hibbard"]
  spec.email = ["eng@niva.co"]

  spec.summary = "Read QR codes and other barcodes from images and PDFs with zxing-cpp (via FFI)."
  spec.description = <<~DESC
    Extracts barcodes (QR and every symbology zxing-cpp can read) from PNG, JPEG, TIFF, GIF, BMP,
    WebP, HEIF, PNM and PDF inputs in any orientation. Binds the zxing-cpp C API with the ffi gem and
    adds a pipeline around it: input sniffing, normalization to 8-bit grayscale, an escalating
    sequence of decode passes, coordinate mapping, deduplication and filtering.
  DESC
  spec.homepage = "https://github.com/withniva/zxing_ffi"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.3"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir[
    "lib/**/*.rb",
    "exe/*",
    "vendor/lib/*",
    "README.md",
    "CHANGELOG.md",
    "LICENSE.txt"
  ]
  spec.bindir = "exe"
  spec.executables = ["zxing-scan"]
  spec.require_paths = ["lib"]

  spec.add_dependency "ffi", ">= 1.16", "< 2"
end
