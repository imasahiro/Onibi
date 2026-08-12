# frozen_string_literal: true

require "benchmark/ips"
require_relative "../lib/onibi"

input = "#{"x" * 4096}alpha-beta".freeze
position = 0
prefilter = Onibi::Experimental::Swar::MultiLiteralPrefilter.new(%w[alpha beta])

def legacy_candidate_positions(prefilter, input, position)
  candidates = []
  states = Array.new(prefilter.buckets.length, 0)
  input.bytes.drop(position).each_with_index do |byte, relative_index|
    prefilter.send(:scan_byte, byte, position + relative_index, states, candidates)
  end
  candidates.uniq.sort
end

expected = legacy_candidate_positions(prefilter, input, position)
raise "candidate implementations disagree" unless prefilter.candidate_positions(input, position) == expected

Benchmark.ips do |x|
  x.config(time: 2, warmup: 1)
  x.report("legacy bytes.drop scan") { legacy_candidate_positions(prefilter, input, position) }
  x.report("zero-copy getbyte scan") { prefilter.candidate_positions(input, position) }
  x.compare!
end
