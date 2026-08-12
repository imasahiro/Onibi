# frozen_string_literal: true

require "benchmark/ips"
require_relative "../lib/onibi"

input = ("abcxyz123" * 64).freeze
run = Onibi::Experimental::Swar::ClassRun.new("a-z")
predicate = Onibi::ClassPredicates.compiled("a-z")

Benchmark.ips do |x|
  x.config(time: 1, warmup: 0.5)
  x.report("baseline class loop") do
    cursor = 0
    cursor += 1 while cursor < input.length && predicate.matches?(input[cursor])
  end
  x.report("class run SWAR") { run.search(input, 0, capture: false) }
  x.compare!
end
