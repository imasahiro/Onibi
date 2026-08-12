# frozen_string_literal: true

require_relative "../../test_helper"

class ImpossibleBranchPruningTest < Minitest::Test
  def test_unconditional_failure_branch_is_removed_at_codegen
    ast = Onibi::Parser.new("(?!)|foo").parse
    program = Onibi::Codegen::GeneratedProgram.ast(ast)

    assert_equal true, program.search("foo", 0, capture: false)
    refute_includes program.source, "input[position, 0]"
  end

  def test_pruned_branch_matches_mri
    pattern = "(?!)|foo"
    input = "prefix foo"

    assert_equal ::Regexp.new(pattern).match?(input), Onibi::Regexp.new(pattern).match?(input)
  end
end
