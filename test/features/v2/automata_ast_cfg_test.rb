# frozen_string_literal: true

require "test_helper"

class V2AutomataAstCfgTest < Minitest::Test
  def test_composite_ast_cfg_operations_become_tnfa_positions
    ast = Onibi::AST::Sequence.new([
                                     Onibi::AST::Literal.new("a"),
                                     Onibi::AST::CharacterClass.new("0-9"),
                                     Onibi::AST::Escape.new(:word),
                                     Onibi::AST::Property.new("Alpha", false),
                                     Onibi::AST::Any.new(".")
                                   ])
    compiled = Onibi::V2::Compiler.compile(ast, passes: [:pure_failure_memoization])
    tnfa = Onibi::V2::Automata::GlushkovTNFA.from_cfg(compiled.graph)

    assert_equal [0], tnfa.start_positions
    assert_equal [4], tnfa.accept_positions
    assert_equal([
                   [:match_literal, Onibi::AST::Literal.new("a")],
                   [:match_class, Onibi::AST::CharacterClass.new("0-9")],
                   [:match_escape, Onibi::AST::Escape.new(:word)],
                   [:match_property, Onibi::AST::Property.new("Alpha", false)],
                   [:match_any, Onibi::AST::Any.new(".")]
                 ], tnfa.positions.map { |position| [position.operation.opcode, position.operation.operand] })
    assert_equal([
                   [:start, 0], [0, 1], [1, 2], [2, 3], [3, 4]
                 ], tnfa.transitions.map { |edge| [edge.from, edge.to] })
  end
end
