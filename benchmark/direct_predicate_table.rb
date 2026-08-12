# frozen_string_literal: true

require "benchmark/ips"
require_relative "../lib/onibi"

input = ("abcxyz" * 128).freeze
predicate = Onibi::ClassPredicates.compiled("a-z")
table = predicate.ascii_table

Benchmark.ips do |benchmark|
  benchmark.config(time: 1, warmup: 0.5)
  benchmark.report("class helper") do
    0.upto(input.length - 1) { |position| Onibi::Codegen::Casefold.class_candidates(input, position, predicate, false) }
  end
  benchmark.report("direct byte table") do
    0.upto(input.length - 1) do |position|
      byte = input.getbyte(position)
      byte && table[byte] ? position + 1 : nil
    end
  end
  benchmark.compare!
end
