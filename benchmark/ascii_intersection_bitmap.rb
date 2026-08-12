# frozen_string_literal: true

require "benchmark/ips"

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "onibi"

source = "a-z&&[^aeiou]"
predicate = Onibi::ClassPredicates.compiled(source)
metadata = predicate.metadata
raise "intersection bitmap was not produced" unless metadata.ascii_applicable

Benchmark.ips do |benchmark|
  benchmark.config(time: 1, warmup: 0.5)
  benchmark.report("runtime intersection predicate (before)") do
    0.upto(127) do |byte|
      Onibi::ClassPredicates.matches?(source, byte.chr(Encoding::ASCII))
    end
  end
  benchmark.report("normalized intersection bitmap (after)") do
    0.upto(127) { |byte| ((metadata.ascii_bitmap >> byte) & 1) == 1 }
  end
  benchmark.compare!
end
