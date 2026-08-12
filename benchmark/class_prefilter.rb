# frozen_string_literal: true

require "benchmark/ips"
require_relative "../lib/onibi"

pattern = "[a-z]\\d+"
input = ("--a2--" * 32).freeze
ast = Onibi::Parser.new(pattern).parse
analysis = Onibi::Codegen::Analyzer.new([]).analyze(ast)
optimized = Onibi::Codegen::GeneratedProgram.ast(ast)
baseline_plan = Onibi::Codegen::SearchPlan.new(
  anchor_start: false, anchor_end: false, minimum_width: analysis.widths.fetch(ast).minimum,
  first_set: nil, required_literal: nil, required_literals: nil, nullable_prefix: true,
  search_mode: :scan, regular_run: nil, class_prefilter: nil
)
baseline = Onibi::Codegen::GeneratedProgram.new(optimized.source, search_plan: baseline_plan)

Benchmark.ips do |x|
  x.config(time: 1, warmup: 0.5)
  x.report("Onibi baseline search plan") { baseline.search(input, 0, capture: false) }
  x.report("Onibi class SWAR prefilter") { optimized.search(input, 0, capture: false) }
  x.compare!
end
