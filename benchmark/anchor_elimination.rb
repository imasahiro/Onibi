# frozen_string_literal: true

require "benchmark/ips"
require_relative "../lib/onibi"

pattern = "elementary\\z"
input = "#{"x" * 2_000}elementary".freeze
ast = Onibi::Parser.new(pattern).parse
optimized = Onibi::Codegen::GeneratedProgram.ast(ast, optimizations: [])
analysis = Onibi::Codegen::Analyzer.new([]).analyze(ast)
baseline_plan = Onibi::Codegen::SearchPlan.new(
  anchor_start: false, anchor_end: false, minimum_width: analysis.widths.fetch(ast).minimum,
  first_set: nil, required_literal: "elementary", required_literals: nil,
  nullable_prefix: false, search_mode: :literal_skip, regular_run: nil, class_prefilter: nil
)
baseline = Onibi::Codegen::GeneratedProgram.new(optimized.source, search_plan: baseline_plan)

Benchmark.ips do |x|
  x.config(time: 1, warmup: 0.5)
  x.report("baseline scan") { baseline.search(input, 0, capture: false) }
  x.report("anchored end elimination") { optimized.search(input, 0, capture: false) }
  x.compare!
end
