# frozen_string_literal: true

require "benchmark/ips"

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "onibi"

# Compares the experimental SWAR candidate prefilter with baseline codegen.
module SwarMultiLiteralBenchmark
  PATTERN = %w[sherlock watson moriarty adler lestrade mycroft hudson].join("|")
  INPUT = "#{"elementary-" * 200}moriarty".freeze

  module_function

  def programs
    ast = Onibi::Parser.new(PATTERN).parse
    {
      "codegen without SWAR" => Onibi::Codegen::GeneratedProgram.ast(ast, optimizations: []),
      "codegen with SWAR" => Onibi::Codegen::GeneratedProgram.ast(ast)
    }
  end

  def results
    programs.transform_values { |program| program.search(INPUT, 0, capture: false) }
  end

  def run(time: 2, warmup: 1)
    raise "SWAR benchmark implementations disagree" unless results.values.uniq == [true]

    benchmark_programs = programs
    Benchmark.ips do |benchmark|
      benchmark.config(time: time, warmup: warmup)
      benchmark_programs.each do |label, program|
        benchmark.report(label) { program.search(INPUT, 0, capture: false) }
      end
      benchmark.compare!
    end
  end
end

SwarMultiLiteralBenchmark.run if $PROGRAM_NAME == __FILE__
