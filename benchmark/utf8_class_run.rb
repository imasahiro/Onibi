# frozen_string_literal: true

require "benchmark/ips"
require_relative "../lib/onibi"

input = "#{"abc" * 1024}é".freeze
run = Onibi::Experimental::Swar::ClassRun.new("a-z")
predicate = Onibi::ClassPredicates.compiled("a-z")

Benchmark.ips do |x|
  x.config(time: 1, warmup: 0.5)
  x.report("UTF-8 ClassRun fallback") { run.search(input, 0, capture: false) }
  x.report("UTF-8 predicate loop") do
    cursor = 0
    input.each_char do |character|
      break unless predicate.matches?(character)

      cursor += 1
    end
  end
  x.compare!
end
