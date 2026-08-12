# frozen_string_literal: true

require "benchmark/ips"
require_relative "../lib/onibi"

input = ("x" * 4096 + "a" * 16).freeze
source = Onibi::Experimental::Swar::ByteSetPrefilter.new(["a".ord])
table = source.table

def legacy_candidates(input, table)
  candidates = []
  0.upto(input.bytesize - 1) do |index|
    candidates << index if table[input.getbyte(index)]
  end
  candidates
end

expected = legacy_candidates(input, table)
raise "candidate implementations disagree" unless source.candidate_positions(input, 0) == expected

Benchmark.ips do |x|
  x.config(time: 2, warmup: 1)
  x.report("legacy byte-table scan") { legacy_candidates(input, table) }
  x.report("singleton String#index scan") { source.candidate_positions(input, 0) }
  x.compare!
end
