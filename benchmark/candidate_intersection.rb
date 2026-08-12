# frozen_string_literal: true

require "benchmark/ips"
require_relative "../lib/onibi"

pattern = "alpha|beta|gamma|delta"
input = "#{"x" * 120}gamma"
ast = Onibi::Parser.new(pattern).parse
default = Onibi::Codegen::GeneratedProgram.ast(ast)
integrated = Onibi::Codegen::GeneratedProgram.ast(ast, optimizations: %i[swar candidate_intersection])

Benchmark.ips do |x|
  x.config(time: 1, warmup: 0.5)
  x.report("single candidate source") { default.search(input, 0, capture: false) }
  x.report("intersected candidate sources") { integrated.search(input, 0, capture: false) }
  x.compare!
end
