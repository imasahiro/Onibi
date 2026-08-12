# frozen_string_literal: true

require_relative "../../test_helper"

class BranchPruningBenchmarkTest < Minitest::Test
  def test_pruned_and_baseline_programs_return_identical_fixture_output # rubocop:disable Metrics/AbcSize
    pattern = "watson|watson|sherlock|sherlock|moriarty"
    input = "#{"elementary-" * 12}moriarty".freeze
    ast = Onibi::Parser.new(pattern).parse
    analysis = Onibi::Codegen::Analyzer.new([]).analyze(ast)
    baseline = Onibi::Codegen::GeneratedProgram.new(
      Onibi::Codegen::RubyGenerator.ast(ast),
      search_plan: Onibi::Codegen::SearchPlan.from(ast, analysis)
    )
    pruned = Onibi::Codegen::GeneratedProgram.ast(ast, optimizations: [])

    assert_equal baseline.search(input, 0, capture: true), pruned.search(input, 0, capture: true)
    assert_equal 1, pruned.source.scan('input[position, 1] == "w"').length
  end

  def test_duplicate_literal_branches_are_pruned_without_changing_result # rubocop:disable Metrics/AbcSize
    pattern = "watson|watson|sherlock"
    ast = Onibi::Parser.new(pattern).parse
    program = Onibi::Codegen::GeneratedProgram.ast(ast)
    expected = ::Regexp.new(pattern).match("sherlock followed")
    actual = Onibi::Regexp.new(pattern).match("sherlock followed")

    assert_equal expected[0], actual[0]
    assert_equal 1, program.source.scan('input[position, 1] == "w"').length
    assert_equal 1, program.source.scan('input[position, 1] == "s"').length
  end
end
