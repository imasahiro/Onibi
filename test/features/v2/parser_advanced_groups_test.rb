# frozen_string_literal: true

require "test_helper"

class V2ParserAdvancedGroupsTest < Minitest::Test
  def test_atomic_group_has_exact_alternation_body
    body = Onibi::AST::Alternation.new([
                                         Onibi::AST::Sequence.new([Onibi::AST::Literal.new("a")]),
                                         Onibi::AST::Sequence.new([Onibi::AST::Literal.new("a"), Onibi::AST::Literal.new("b")])
                                       ])

    assert_equal Onibi::AST::Sequence.new([Onibi::AST::AtomicGroup.new(body)]),
                 Onibi::Parser.parse("(?>a|ab)").ast
  end

  def test_absence_group_has_exact_nested_body
    body = Onibi::AST::Sequence.new([
                                      Onibi::AST::Group.new(
                                        Onibi::AST::Sequence.new([Onibi::AST::Literal.new("a")]), 1, true, nil
                                      )
                                    ])

    assert_equal Onibi::AST::Sequence.new([Onibi::AST::Absence.new(body)]),
                 Onibi::Parser.parse("(?~(a))").ast
  end

  def test_scoped_option_group_has_exact_flags
    body = Onibi::AST::Sequence.new(%w[c a t].map { |value| Onibi::AST::Literal.new(value) })
    expected = Onibi::AST::Sequence.new([Onibi::AST::OptionGroup.new(body, true, nil, nil)])

    assert_equal expected, Onibi::Parser.parse("(?i:cat)").ast
  end
end
