# frozen_string_literal: true

require "test_helper"

class ParserTest < Minitest::Test
  def test_alternation_has_lower_precedence_than_concatenation
    ast = Onibi::Parser.new("ab|cd").parse

    assert_instance_of Onibi::AST::Alternation, ast
    branches = ast.branches.map { |branch| branch.parts.map(&:value).join }

    assert_equal %w[ab cd], branches
  end

  def test_groups_and_quantifiers_are_nested_in_the_expected_order
    ast = Onibi::Parser.new("a(b|c)d+").parse

    assert_instance_of Onibi::AST::Sequence, ast
    assert_instance_of Onibi::AST::Group, ast.parts[1]
    assert_instance_of Onibi::AST::Quantifier, ast.parts[2]
    assert_equal :+, ast.parts[2].kind
  end
end
