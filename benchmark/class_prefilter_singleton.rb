# frozen_string_literal: true

require "benchmark/ips"
require_relative "../lib/onibi"

input = ("x" * 4096 + "a" * 16).freeze
source = Onibi::Experimental::Swar::ClassPrefilter.new("a")
table = Array.new(256) { |byte| Onibi::ClassPredicates.compiled("a").matches?(byte.chr(Encoding::ASCII_8BIT)) }

def legacy_candidates(input, table)
  candidates = []
  cursor = 0
  while cursor < input.bytesize
    limit = [cursor + Onibi::Experimental::Swar::WORD_BITS / 8, input.bytesize].min
    cursor.upto(limit - 1) do |index|
      candidates << index if table[input.getbyte(index)]
    end
    cursor = limit
  end
  candidates
end

expected = legacy_candidates(input, table)
raise "candidate implementations disagree" unless source.candidate_positions(input, 0) == expected

Benchmark.ips do |x|
  x.config(time: 2, warmup: 1)
  x.report("legacy class table scan") { legacy_candidates(input, table) }
  x.report("singleton String#index scan") { source.candidate_positions(input, 0) }
  x.compare!
end
