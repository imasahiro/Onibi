# frozen_string_literal: true

require "benchmark/ips"
require_relative "../lib/onibi"

input = "#{"a" * 4096},tail".freeze
run = Onibi::Experimental::Swar::ClassRun.new("^,\\n")
predicate = Onibi::ClassPredicates.compiled("^,\\n")

Benchmark.ips do |x|
  x.config(time: 1, warmup: 0.5)
  x.report("byte predicate loop") do
    cursor = 0
    cursor += 1 while cursor < input.length && predicate.matches?(input[cursor])
  end
  x.report("negated class SWAR") { run.search(input, 0, capture: false) }
  x.compare!
end
