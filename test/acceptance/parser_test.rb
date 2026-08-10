# frozen_string_literal: true

require "test_helper"

class ParserTest < Minitest::Test
  def test_alternation_has_lower_precedence_than_concatenation
    ast = Onibi::Parser.new("ab|cd").parse

    assert_instance_of Onibi::AST::Alternation, ast
    assert_equal %w[ab cd], ast.branches.map { |branch| branch.parts.map(&:value).join }
  end

  def test_groups_and_quantifiers_are_nested_in_the_expected_order
    ast = Onibi::Parser.new("a(b|c)d+").parse

    assert_instance_of Onibi::AST::Sequence, ast
    assert_instance_of Onibi::AST::Group, ast.parts[1]
    assert_instance_of Onibi::AST::Quantifier, ast.parts[2]
    assert_equal :+, ast.parts[2].kind
  end

  def test_public_construction_validates_parser_precedence
    assert_silent { Onibi::Regexp.new("a(b|c)d+") }
  end
end
