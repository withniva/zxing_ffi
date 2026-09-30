# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"

TEST_SUITES = %w[unit native integration corpus].freeze

namespace :test do
  TEST_SUITES.each do |suite|
    Rake::TestTask.new(suite) do |t|
      t.libs << "test" << "lib"
      t.test_files = FileList["test/#{suite}/**/*_test.rb"]
      t.warning = false
    end
  end
end

desc "Run all test suites (#{TEST_SUITES.join(", ")})"
Rake::TestTask.new(:test) do |t|
  t.libs << "test" << "lib"
  t.test_files = FileList[*TEST_SUITES.map { |s| "test/#{s}/**/*_test.rb" }]
  t.warning = false
end

begin
  require "standard/rake"
rescue LoadError
  # standard is a development dependency
end

begin
  require "yard"
  YARD::Rake::YardocTask.new(:yard)
rescue LoadError
  # yard is a development dependency
end

desc "Regenerate committed test fixtures (needs zint, rqrcode, prawn, ImageMagick, libvips, poppler)"
task :fixtures do
  ruby "script/generate_fixtures"
end

task default: %i[test standard]
