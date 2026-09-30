# frozen_string_literal: true

source "https://rubygems.org"

gemspec

group :development, :test do
  gem "rake", "~> 13.0"
  gem "minitest", ">= 5.25"
  gem "standard", "~> 1.40"
  gem "yard", "~> 0.9"
  # Soft runtime dependency: enables VipsLoader and the Vips transformer.
  gem "ruby-vips", "~> 2.2"
end

# Only needed to regenerate test fixtures (script/generate_fixtures).
group :fixtures do
  gem "rqrcode", "~> 3.0"
  gem "prawn", "~> 2.5"
  gem "prawn-svg", "~> 0.36"
end
