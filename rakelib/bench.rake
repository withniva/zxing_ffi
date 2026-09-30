# frozen_string_literal: true

desc "Benchmark the golden corpus (EFFORTS=fast,normal,thorough STOP=found OUT=docs/benchmark.md)"
task :bench do
  ruby File.expand_path("../script/bench", __dir__)
end
