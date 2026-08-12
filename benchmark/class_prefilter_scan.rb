# frozen_string_literal: true

require "benchmark/ips"
require_relative "../lib/onibi"

input = "#{"x" * 4096}abcxyz".freeze
source = Onibi::Experimental::Swar::ClassPrefilter.new("a-z")
expected = source.each_candidate(input, 0).to_a
raise "candidate implementations disagree" unless source.candidate_positions(input, 0) == expected

Benchmark.ips do |x|
  x.config(time: 2, warmup: 1)
  x.report("callback candidate scan") { source.each_candidate(input, 0).to_a }
  x.report("direct candidate array") { source.candidate_positions(input, 0) }
  x.compare!
end
