# frozen_string_literal: true

require "benchmark/ips"
require_relative "../lib/onibi"

prefix = "abcdefghij" * 4
pattern = "#{prefix}[a]|#{prefix}[b]|#{prefix}[c]|#{prefix}[d]"
ast = Onibi::Parser.new(pattern).parse
optimized = Onibi::Codegen::GeneratedProgram.ast(ast, optimizations: [])
baseline_source = optimized.source
                           .sub(/^ONIBI_LITERAL_VALUES = .*\n/, "")
                           .gsub("ONIBI_LITERAL_VALUES", prefix.dump)
baseline = Onibi::Codegen::GeneratedProgram.new(baseline_source, search_plan: optimized.search_plan)
input = ("x" * 256 + "#{prefix}z").freeze

raise "generated programs disagree" unless baseline.search(input, 0,
                                                           capture: true) == optimized.search(input, 0, capture: true)

puts "source bytes: #{baseline.source.bytesize} -> #{optimized.source.bytesize}"

Benchmark.ips do |benchmark|
  benchmark.config(time: 1, warmup: 0.5)
  benchmark.report("repeated inline literals (before)") { baseline.search(input, 0, capture: false) }
  benchmark.report("shared literal table (after)") { optimized.search(input, 0, capture: false) }
  benchmark.compare!
end
