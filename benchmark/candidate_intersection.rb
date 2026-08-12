# frozen_string_literal: true

require "benchmark/ips"
require_relative "../lib/onibi"

pattern = "alpha|beta|gamma|delta"
input = "#{"x" * 120}gamma"
ast = Onibi::Parser.new(pattern).parse
default = Onibi::Codegen::GeneratedProgram.ast(ast)
integrated = Onibi::Codegen::GeneratedProgram.ast(ast, optimizations: %i[swar candidate_intersection])

no_match_input = ("x" * 4096).freeze
first = Onibi::Experimental::Swar::ByteSetPrefilter.new(["z".ord])
second = Onibi::Experimental::Swar::MultiLiteralPrefilter.new(%w[alpha beta])
intersection = Onibi::Codegen::CandidateSource::Intersection.new([first, second])

def legacy_intersection(sources, input, position)
  candidates = sources.first.candidate_positions(input, position).uniq
  sources.drop(1).each do |source|
    allowed = source.candidate_positions(input, position).to_h { |candidate| [candidate, true] }
    candidates.select! { |candidate| allowed[candidate] }
  end
  candidates
end

legacy_candidates = legacy_intersection([first, second], no_match_input, 0)
optimized_candidates = intersection.candidate_positions(no_match_input, 0)
raise "candidate intersections disagree" unless legacy_candidates == optimized_candidates

Benchmark.ips do |x|
  x.config(time: 1, warmup: 0.5)
  x.report("single candidate source") { default.search(input, 0, capture: false) }
  x.report("intersected candidate sources") { integrated.search(input, 0, capture: false) }
  x.report("legacy empty intersection") { legacy_intersection([first, second], no_match_input, 0) }
  x.report("short-circuit empty intersection") { intersection.candidate_positions(no_match_input, 0) }
  x.compare!
end
