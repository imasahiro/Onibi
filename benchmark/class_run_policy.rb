# frozen_string_literal: true

require "benchmark/ips"
require_relative "../lib/onibi"

input = ("abcxyz" * 128).freeze
predicate = Onibi::ClassPredicates.compiled("a-z")
run = Onibi::Experimental::Swar::ClassRun.new("a-z")

Benchmark.ips do |x|
  x.config(time: 1, warmup: 0.5)
  x.report("scalar class run") do
    cursor = 0
    cursor += 1 while cursor < input.bytesize && predicate.matches_byte?(input.getbyte(cursor))
  end
  x.report("adaptive class-run SWAR") { run.search(input, 0, capture: false) }
  x.compare!
end
