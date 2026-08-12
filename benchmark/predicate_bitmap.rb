# frozen_string_literal: true

require "benchmark/ips"
require_relative "../lib/onibi"

source = "a-cx-z"
predicate = Onibi::ClassPredicates.compiled(source)
bitmap = predicate.metadata.ascii_bitmap
input = (0..255).to_a.freeze

Benchmark.ips do |x|
  x.config(time: 1, warmup: 0.5)
  x.report("source predicate") do
    input.each { |byte| Onibi::ClassPredicates.match_source(source, byte.chr(Encoding::ASCII_8BIT), false) }
  end
  x.report("256-bit bitmap") { input.each { |byte| ((bitmap >> byte) & 1) == 1 } }
  x.compare!
end
