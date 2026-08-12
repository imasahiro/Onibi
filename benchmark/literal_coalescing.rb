# frozen_string_literal: true

require "benchmark/ips"
require_relative "../lib/onibi"

pattern = "abcdefgh"
input = ("x" * 120 + pattern).freeze
ast = Onibi::Parser.new(pattern).parse
program = Onibi::Codegen::GeneratedProgram.ast(ast, optimizations: [])

Benchmark.ips do |x|
  x.config(time: 1, warmup: 0.5)
  x.report("coalesced literal run") { program.search(input, 0, capture: false) }
  x.compare!
end
