# frozen_string_literal: true

require "benchmark/ips"
require_relative "../lib/onibi"

pattern = "(?<outer>foo)(?:a)+z"
input = "foo#{"a" * 1_000}y".freeze
program = Onibi::Codegen::GeneratedProgram.ast(Onibi::Parser.new(pattern).parse)

puts "source_bytes=#{program.source.bytesize}"
Benchmark.ips do |benchmark|
  benchmark.config(time: 1, warmup: 0.5)
  benchmark.report("outer capture with quantifier") { program.search(input, 0, capture: true) }
end
