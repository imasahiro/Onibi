# frozen_string_literal: true

require "benchmark/ips"

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "onibi"

# Compares the experimental SWAR candidate prefilter with baseline codegen.
module SwarMultiLiteralBenchmark
  BenchmarkCase = Struct.new(:pattern, :input, :expected, :optimizations, keyword_init: true)
  WORD_BITS = Onibi::Experimental::Swar::WORD_BITS
  WORD_LITERALS = ["a" * WORD_BITS, "b" * WORD_BITS, "c" * WORD_BITS].freeze
  LONG_LITERALS = ["a" * (WORD_BITS + 1), "b" * (WORD_BITS + 2), "c" * (WORD_BITS + 3)].freeze
  CASES = {
    regular_late: BenchmarkCase.new(
      pattern: %w[sherlock watson moriarty adler lestrade mycroft hudson].join("|"),
      input: "#{"elementary-" * 200}moriarty",
      expected: true
    ),
    one_character_early: BenchmarkCase.new(
      pattern: "a|b|c|d|e|f|g|h", input: "a", expected: true,
      optimizations: %i[swar swar_single_character]
    ),
    one_character_late: BenchmarkCase.new(
      pattern: "a|b|c|d|e|f|g|h", input: "#{"x" * 2_000}h", expected: true,
      optimizations: %i[swar swar_single_character]
    ),
    word_width_early: BenchmarkCase.new(
      pattern: WORD_LITERALS.join("|"), input: WORD_LITERALS.first, expected: true,
      optimizations: %i[swar swar_long_literals]
    ),
    word_width_late: BenchmarkCase.new(
      pattern: WORD_LITERALS.join("|"), input: "#{"x" * 2_000}#{WORD_LITERALS.last}", expected: true,
      optimizations: %i[swar swar_long_literals]
    ),
    over_word_early: BenchmarkCase.new(
      pattern: LONG_LITERALS.join("|"), input: LONG_LITERALS.first, expected: true,
      optimizations: %i[swar swar_long_literals]
    ),
    over_word_late: BenchmarkCase.new(
      pattern: LONG_LITERALS.join("|"), input: "#{"x" * 2_000}#{LONG_LITERALS.last}", expected: true,
      optimizations: %i[swar swar_long_literals]
    )
  }.freeze

  module_function

  def programs(benchmark_case)
    ast = Onibi::Parser.new(benchmark_case.pattern).parse
    {
      "codegen without SWAR" => Onibi::Codegen::GeneratedProgram.ast(ast, optimizations: []),
      "codegen with SWAR" => Onibi::Codegen::GeneratedProgram.ast(
        ast, optimizations: benchmark_case.optimizations || [:swar]
      )
    }
  end

  def results
    CASES.transform_values do |benchmark_case|
      programs(benchmark_case).transform_values do |program|
        program.search(benchmark_case.input, 0, capture: false)
      end
    end
  end

  def run(time: 2, warmup: 1)
    validate_results!
    CASES.each do |name, benchmark_case|
      puts "\n#{name}"
      run_case(benchmark_case, time: time, warmup: warmup)
    end
  end

  def validate_results!
    results.each do |name, variants|
      expected = CASES.fetch(name).expected
      raise "#{name} implementations disagree" unless variants.values.uniq == [expected]
    end
  end

  def run_case(benchmark_case, time:, warmup:)
    benchmark_programs = programs(benchmark_case)
    Benchmark.ips do |benchmark|
      benchmark.config(time: time, warmup: warmup)
      benchmark_programs.each do |label, program|
        benchmark.report(label) { program.search(benchmark_case.input, 0, capture: false) }
      end
      benchmark.compare!
    end
  end
end

SwarMultiLiteralBenchmark.run if $PROGRAM_NAME == __FILE__
