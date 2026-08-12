# frozen_string_literal: true

require "benchmark/ips"
require_relative "../lib/onibi"

Source = Struct.new(:candidates) do
  def eligible?(*_arguments)
    true
  end

  def candidate_positions(_input, _position)
    candidates
  end

  def preserves_order?
    true
  end
end

sources = [
  [1, 5, 9, 13, 17, 21],
  [2, 5, 8, 11, 14, 17, 20],
  [0, 4, 10, 16, 22, 28]
].map { |candidates| Source.new(candidates) }
union = Onibi::Codegen::CandidateSource::Union.new(sources)

def legacy_union(sources, input, position)
  sources.filter_map do |source|
    source.candidates if source.eligible?(input, position)
  end.flatten.uniq.sort
end

expected = legacy_union(sources, "input", 0)
raise "candidate unions disagree" unless union.candidate_positions("input", 0) == expected

Benchmark.ips do |benchmark|
  benchmark.config(time: 1, warmup: 0.5)
  benchmark.report("flat_map + uniq + sort") { legacy_union(sources, "input", 0) }
  benchmark.report("ordered CandidateSource::Union") { union.candidate_positions("input", 0) }
  benchmark.compare!
end
