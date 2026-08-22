# frozen_string_literal: true

require "test_helper"

class V2AutomataTest < Minitest::Test
  def test_cfg_converts_to_glushkov_tnfa_and_partial_dfa
    compiled = Onibi::V2::Compiler.compile(Onibi::V2::Parser.parse("a."))
    tnfa = Onibi::V2::Automata::GlushkovTNFA.from_cfg(compiled.graph)

    assert_equal 1, tnfa.start_positions.length
    assert_equal 2, tnfa.positions.length
    assert_equal 1, tnfa.accept_positions.length

    dfa = Onibi::V2::Automata::DFA.from_tnfa(tnfa)
    partial = Onibi::V2::Automata::PartialDFA.from_tnfa(tnfa, state_limit: 1)
    assert_operator dfa.states.length, :>=, 2
    assert_equal true, partial.partial?
    assert_operator partial.states.length, :<=, 1
  end

  def test_tnfa_graph_has_expected_positions_and_opcodes
    compiled = Onibi::V2::Compiler.compile(Onibi::V2::Parser.parse("a."))
    tnfa = Onibi::V2::Automata::GlushkovTNFA.from_cfg(compiled.graph)
    expected_positions = [
      [0, :match_literal, Onibi::AST::Literal.new("a")],
      [1, :match_any, Onibi::AST::Any.new(".")]
    ]
    expected_edges = [
      [:start, 0, :match_literal, Onibi::AST::Literal.new("a")],
      [0, 1, :match_any, Onibi::AST::Any.new(".")]
    ]

    assert_equal(expected_positions, tnfa.positions.map { |position| [position.id, position.operation.opcode, position.operation.operand] })
    assert_equal(expected_edges, tnfa.transitions.map { |edge| [edge.from, edge.to, edge.operation.opcode, edge.operation.operand] })
  end

  def test_alternation_keeps_all_start_and_accept_positions
    compiled = Onibi::V2::Compiler.compile(Onibi::V2::Parser.parse("a|b"))
    tnfa = Onibi::V2::Automata::GlushkovTNFA.from_cfg(compiled.graph)

    assert_equal [0, 1], tnfa.start_positions
    assert_equal [0, 1], tnfa.accept_positions
    dfa = Onibi::V2::Automata::DFA.from_tnfa(tnfa)
    assert_equal [], dfa.start_state.positions
    assert_equal [[0], [1]], dfa.states.drop(1).map(&:positions)
  end

  def test_dfa_transition_targets_are_state_ids
    compiled = Onibi::V2::Compiler.compile(Onibi::V2::Parser.parse("a."))
    tnfa = Onibi::V2::Automata::GlushkovTNFA.from_cfg(compiled.graph)
    dfa = Onibi::V2::Automata::DFA.from_tnfa(tnfa)

    assert(dfa.transitions.values.all? { |target| target.is_a?(Integer) })
  end
end
