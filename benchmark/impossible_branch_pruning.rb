# frozen_string_literal: true

require "benchmark/ips"
require_relative "../lib/onibi"

pattern = "(?!)|foo"
input = "#{"x" * 2_000}foo"
ast = Onibi::Parser.new(pattern).parse
analysis = Onibi::Codegen::Analyzer.new([], Encoding::UTF_8).analyze(ast)
baseline = Onibi::Codegen::GeneratedProgram.ast(ast, optimizations: [], analysis: analysis)
optimized = Onibi::Codegen::GeneratedProgram.ast(ast, optimizations: [])
raise "results differ" unless baseline.search(input, 0, capture: false) == optimized.search(input, 0, capture: false)

Benchmark.ips do |benchmark|
  benchmark.config(time: 1, warmup: 0.5)
  benchmark.report("baseline branch") { baseline.search(input, 0, capture: false) }
  benchmark.report("pruned branch") { optimized.search(input, 0, capture: false) }
  benchmark.compare!
end
