# frozen_string_literal: true

require "benchmark/ips"

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "onibi"

input = ("abcxyz" * 32).freeze
predicate = Onibi::ClassPredicates.compiled("a-z")

def legacy_class_candidates(input, predicate)
  result = 0
  0.upto(input.length - 1) do |position|
    result += 1 if input[position] && predicate.matches?(input[position])
  end
  result
end

expected = legacy_class_candidates(input, predicate)
raise "helper results disagree" unless expected == input.length

Benchmark.ips do |benchmark|
  benchmark.config(time: 1, warmup: 0.5)
  benchmark.report("character slicing + predicate (before)") { legacy_class_candidates(input, predicate) }
  benchmark.report("byte table helper (after)") do
    0.upto(input.length - 1) do |position|
      Onibi::Codegen::Casefold.class_candidates(input, position, predicate, false)
    end
  end
  benchmark.compare!
end
