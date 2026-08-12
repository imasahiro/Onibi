# frozen_string_literal: true

require "benchmark/ips"
require_relative "../lib/onibi"

pattern = "a|[b]|c"
input = "#{"x" * 2_000}b".freeze
ast = Onibi::Parser.new(pattern).parse
optimized = Onibi::Codegen::GeneratedProgram.ast(ast, optimizations: [])
plan = optimized.search_plan
baseline_plan = Onibi::Codegen::SearchPlan.new(
  **plan.to_h.merge(class_prefilter: nil, candidate_source: nil, search_mode: :scan)
)
baseline = Onibi::Codegen::GeneratedProgram.new(optimized.source, search_plan: baseline_plan)

baseline_result = baseline.search(input, 0, capture: false)
optimized_result = optimized.search(input, 0, capture: false)
raise "candidate results differ" if baseline_result != optimized_result

Benchmark.ips do |benchmark|
  benchmark.config(time: 1, warmup: 0.5)
  benchmark.report("baseline scan") { baseline.search(input, 0, capture: false) }
  benchmark.report("ASCII alternation first-set") { optimized.search(input, 0, capture: false) }
  benchmark.compare!
end
