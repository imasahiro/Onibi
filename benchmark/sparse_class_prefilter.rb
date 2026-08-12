# frozen_string_literal: true

require "benchmark/ips"
require_relative "../lib/onibi"

input = "#{"x" * 2048}abc#{"x" * 2048}".freeze
predicate = Onibi::ClassPredicates.compiled("abc")
prefilter = Onibi::Experimental::Swar::ClassPrefilter.new("abc")

def baseline_candidates(input, predicate)
  table = predicate.ascii_table
  (0...input.bytesize).filter { |index| table[input.getbyte(index)] }
end

expected = baseline_candidates(input, predicate)
raise "candidate results disagree" unless prefilter.candidate_positions(input, 0) == expected

Benchmark.ips do |benchmark|
  benchmark.config(time: 1, warmup: 0.5)
  benchmark.report("sparse table scan (before)") { baseline_candidates(input, predicate) }
  benchmark.report("sparse String#index scan (after)") { prefilter.candidate_positions(input, 0) }
  benchmark.compare!
end
