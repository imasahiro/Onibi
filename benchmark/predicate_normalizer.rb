# frozen_string_literal: true

require "benchmark/ips"
require_relative "../lib/onibi"

source = "a-cx-z"
predicate = Onibi::ClassPredicates.compiled(source)
input = (0..127).map(&:chr).join.freeze

Benchmark.ips do |x|
  x.config(time: 1, warmup: 0.5)
  x.report("source predicate scan") do
    input.each_char { |character| Onibi::ClassPredicates.match_source(source, character, false) }
  end
  x.report("normalized table scan") do
    input.each_byte { |byte| predicate.matches_byte?(byte) }
  end
  x.compare!
end
