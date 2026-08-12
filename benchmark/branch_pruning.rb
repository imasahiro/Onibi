# frozen_string_literal: true

require "benchmark/ips"
require_relative "../lib/onibi"

pattern = "watson|watson|sherlock|sherlock|moriarty"
input = "#{"elementary-" * 120}moriarty".freeze
ast = Onibi::Parser.new(pattern).parse
analysis = Onibi::Codegen::Analyzer.new([]).analyze(ast)
baseline = Onibi::Codegen::GeneratedProgram.new(
  Onibi::Codegen::RubyGenerator.ast(ast),
  search_plan: Onibi::Codegen::SearchPlan.from(ast, analysis)
)
pruned = Onibi::Codegen::GeneratedProgram.ast(ast, optimizations: [])

Benchmark.ips do |x|
  x.config(time: 1, warmup: 0.5)
  x.report("baseline duplicate branches") { baseline.search(input, 0, capture: false) }
  x.report("pruned duplicate branches") { pruned.search(input, 0, capture: false) }
  x.compare!
end
