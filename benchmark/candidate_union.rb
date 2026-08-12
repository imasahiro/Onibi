# frozen_string_literal: true

require "benchmark/ips"
require_relative "../lib/onibi"

# Provides deterministic ordered candidates for the benchmark fixture.
class StaticCandidates
  include Onibi::Codegen::CandidateSource

  def initialize(candidates)
    @candidates = candidates.freeze
  end

  def eligible?(_input, _position) = true

  def candidate_positions(_input, _position) = @candidates
end

left = StaticCandidates.new((0...2048).step(3).to_a)
single_union = Onibi::Codegen::CandidateSource::Union.new([left])

def baseline_single_union(source)
  [source.candidate_positions("", 0)].flatten.uniq.sort!
end

raise "single candidate union mismatch" unless single_union.candidate_positions("", 0) == baseline_single_union(left)

Benchmark.ips do |benchmark|
  benchmark.config(time: 1, warmup: 0.5)
  benchmark.report("single stream flatten (before)") { baseline_single_union(left) }
  benchmark.report("single stream passthrough (after)") { single_union.candidate_positions("", 0) }
  benchmark.compare!
end
