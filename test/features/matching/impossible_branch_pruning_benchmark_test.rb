# frozen_string_literal: true

require_relative "../../test_helper"

class ImpossibleBranchPruningBenchmarkTest < Minitest::Test
  def test_pruned_and_baseline_programs_match
    pattern = "(?!)|foo"
    input = "prefix foo"
    ast = Onibi::Parser.new(pattern).parse
    analysis = Onibi::Codegen::Analyzer.new([], Encoding::UTF_8).analyze(ast)
    baseline = Onibi::Codegen::GeneratedProgram.ast(ast, optimizations: [], analysis: analysis)
    optimized = Onibi::Codegen::GeneratedProgram.ast(ast, optimizations: [])

    assert_equal baseline.search(input, 0, capture: true), optimized.search(input, 0, capture: true)
    assert_equal ::Regexp.new(pattern).match?(input), Onibi::Regexp.new(pattern).match?(input)
  end
end
