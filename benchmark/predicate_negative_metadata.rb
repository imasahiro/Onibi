# frozen_string_literal: true

require "benchmark/ips"

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "onibi"

source = "^a-c"
predicate = Onibi::ClassPredicates.compiled(source)
raise "metadata mismatch" unless predicate.metadata.ascii_negative == source.start_with?("^")

Benchmark.ips do |benchmark|
  benchmark.config(time: 1, warmup: 0.5)
  benchmark.report("source scan (before)") { source.start_with?("^") }
  benchmark.report("normalized metadata (after)") { predicate.metadata.ascii_negative }
  benchmark.compare!
end
