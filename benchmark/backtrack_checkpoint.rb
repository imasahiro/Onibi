# frozen_string_literal: true

require "benchmark/ips"
require_relative "../lib/onibi"

INPUT = "#{"a" * 240}z".freeze

def legacy_checkpoint_candidates(*)
  captures = []
  candidates = []
  cursor = 0
  241.times do
    candidates << [cursor, captures.map(&:dup)]
    cursor += 1
  end
  candidates
end

def position_checkpoint_candidates(*)
  candidates = []
  cursor = 0
  241.times do
    candidates << cursor
    cursor += 1
  end
  candidates
end

ast = Onibi::Parser.new("a.*z").parse
program = Onibi::Codegen::GeneratedProgram.ast(ast, optimizations: [])

Benchmark.ips do |x|
  x.config(time: 1, warmup: 0.5)
  x.report("capture snapshot checkpoint") { legacy_checkpoint_candidates(INPUT) }
  x.report("position-only checkpoint") { position_checkpoint_candidates(INPUT) }
  x.report("generated matcher") { program.search(INPUT, 0, capture: false) }
  x.compare!
end
