# frozen_string_literal: true

require "benchmark/ips"
require_relative "../lib/onibi"

pattern = "\\Gfoo"
input = "#{"x" * 2_000}foo".freeze
ast = Onibi::Parser.new(pattern).parse
optimized = Onibi::Codegen::GeneratedProgram.ast(ast, optimizations: [])
plan = optimized.search_plan
baseline_plan = Onibi::Codegen::SearchPlan.new(
  **plan.to_h.merge(origin_start: false, search_mode: :scan, candidate_source: nil)
)
baseline = Onibi::Codegen::GeneratedProgram.new(optimized.source, search_plan: baseline_plan)

baseline_result = baseline.search(input, 0, capture: false)
optimized_result = optimized.search(input, 0, capture: false)
raise "candidate results differ" if baseline_result != optimized_result

Benchmark.ips do |benchmark|
  benchmark.config(time: 1, warmup: 0.5)
  benchmark.report("baseline candidate scan") { baseline.search(input, 0, capture: false) }
  benchmark.report("\\G origin restriction") { optimized.search(input, 0, capture: false) }
  benchmark.compare!
end
