# frozen_string_literal: true

require "test_helper"

class V2AutomataTest < Minitest::Test
  def test_tagged_tnfa_retains_operation_effect_tags
    cfg = Onibi::Compiler.compile(Onibi::Parser.parse("(a)")).graph
    tnfa = Onibi::Automata::GlushkovTNFA.from_cfg(cfg)
    tagged = Onibi::Automata::TaggedTNFA.from_tnfa(tnfa)

    assert(tagged.transitions.any? { |edge| edge.tags.any? { |tag| tag.kind == :capture } })
  end

  def test_tagged_dfa_retains_transition_tags
    cfg = Onibi::Compiler.compile(Onibi::Parser.parse("(a)")).graph
    tagged = Onibi::Automata::TaggedDFA.from_tagged_tnfa(
      Onibi::Automata::TaggedTNFA.from_tnfa(Onibi::Automata::GlushkovTNFA.from_cfg(cfg))
    )

    assert(tagged.transitions.keys.any? { |key| key.length == 3 && key.last.any? })
  end

  def test_literal_cfg_becomes_one_tnfa_position_and_accepting_dfa_state
    literal = Onibi::AST::Literal.new("a")
    tnfa, dfa = automata_for(literal)

    assert_equal [[0, :match_literal, literal]], position_signature(tnfa)
    assert_equal [[:start, 0, :match_literal, literal]], transition_signature(tnfa)
    assert_equal [0], tnfa.start_positions
    assert_equal [0], tnfa.accept_positions
    assert_equal [[0, [], false], [1, [0], true]], state_signature(dfa)
    assert_equal [[0, :match_literal, literal, 1]], dfa_transition_signature(dfa)
  end

  def test_character_class_cfg_preserves_class_opcode_in_tnfa_and_dfa
    character_class = Onibi::AST::CharacterClass.new("a-z")
    tnfa, dfa = automata_for(character_class)

    assert_equal [[0, :match_class, character_class]], position_signature(tnfa)
    assert_equal [[:start, 0, :match_class, character_class]], transition_signature(tnfa)
    assert_equal [[0, :match_class, character_class, 1]], dfa_transition_signature(dfa)
  end

  def test_escape_property_and_any_cfgs_preserve_their_match_opcodes
    nodes = [
      [Onibi::AST::Escape.new(:digit), :match_escape],
      [Onibi::AST::Property.new("Alpha", false), :match_property],
      [Onibi::AST::Any.new("."), :match_any]
    ]

    nodes.each do |node, opcode|
      tnfa, dfa = automata_for(node)

      assert_equal [[0, opcode, node]], position_signature(tnfa), opcode
      assert_equal [[:start, 0, opcode, node]], transition_signature(tnfa), opcode
      assert_equal [[0, opcode, node, 1]], dfa_transition_signature(dfa), opcode
    end
  end

  def test_sequence_cfg_creates_ordered_tnfa_edges_and_dfa_states
    ast = sequence("a", "b")
    literal_a = ast.parts[0]
    literal_b = ast.parts[1]
    tnfa, dfa = automata_for(ast)

    assert_equal [[0, :match_literal, literal_a], [1, :match_literal, literal_b]],
                 position_signature(tnfa)
    assert_equal [
      [:start, 0, :match_literal, literal_a],
      [0, 1, :match_literal, literal_b]
    ], transition_signature(tnfa)
    assert_equal [[0, [], false], [1, [0], false], [2, [1], true]], state_signature(dfa)
    assert_equal [
      [0, :match_literal, literal_a, 1],
      [1, :match_literal, literal_b, 2]
    ], dfa_transition_signature(dfa)
  end

  def test_choice_cfg_creates_all_tnfa_start_edges_and_dfa_branches
    ast = Onibi::AST::Alternation.new([sequence("a"), sequence("b")])
    literal_a = ast.branches[0].parts.first
    literal_b = ast.branches[1].parts.first
    tnfa, dfa = automata_for(ast)

    assert_equal [0, 1], tnfa.start_positions
    assert_equal [0, 1], tnfa.accept_positions
    assert_equal [
      [:start, 0, :match_literal, literal_a],
      [:start, 1, :match_literal, literal_b]
    ], transition_signature(tnfa)
    assert_equal [[0, [], false], [1, [0], true], [2, [1], true]], state_signature(dfa)
    assert_equal [
      [0, :match_literal, literal_a, 1],
      [0, :match_literal, literal_b, 2]
    ], dfa_transition_signature(dfa)
  end

  def test_repeat_cfg_keeps_quantifier_opcode_and_operand_in_automata
    quantifier = Onibi::AST::Quantifier.new(Onibi::AST::Literal.new("a"), :+, 1, nil, :greedy)
    tnfa, dfa = automata_for(quantifier)

    assert_equal [[0, :match_quantifier, quantifier]], position_signature(tnfa)
    assert_equal [[:start, 0, :match_quantifier, quantifier]], transition_signature(tnfa)
    assert_equal [0], tnfa.accept_positions
    assert_equal [[0, :match_quantifier, quantifier, 1]], dfa_transition_signature(dfa)
  end

  def test_capture_cfg_preserves_group_opcode_and_capture_metadata
    group = Onibi::AST::Group.new(sequence("a"), 1, true, "name")
    tnfa, dfa = automata_for(group)

    assert_equal [[0, :match_group, group]], position_signature(tnfa)
    assert_equal [[:start, 0, :match_group, group]], transition_signature(tnfa)
    assert_equal [[0, :match_group, group, 1]], dfa_transition_signature(dfa)
  end

  def test_atomic_group_cfg_preserves_atomic_opcode_and_operand
    atomic = Onibi::AST::AtomicGroup.new(sequence("a", "b"))
    tnfa, dfa = automata_for(atomic)

    assert_equal [[0, :match_atomic_group, atomic]], position_signature(tnfa)
    assert_equal [[:start, 0, :match_atomic_group, atomic]], transition_signature(tnfa)
    assert_equal [[0, :match_atomic_group, atomic, 1]], dfa_transition_signature(dfa)
  end

  def test_assertion_and_anchor_cfgs_preserve_semantic_opcodes
    nodes = [
      [Onibi::AST::Assertion.new(sequence("a"), :positive), :match_assertion],
      [Onibi::AST::Anchor.new(:anchor_start), :test_anchor],
      [Onibi::AST::Absence.new(sequence("a")), :match_absence]
    ]

    nodes.each do |node, opcode|
      tnfa, dfa = automata_for(node)

      assert_equal [[0, opcode, node]], position_signature(tnfa), opcode
      assert_equal [[:start, 0, opcode, node]], transition_signature(tnfa), opcode
      assert_equal [[0, opcode, node, 1]], dfa_transition_signature(dfa), opcode
    end
  end

  def test_backreference_conditional_and_subexpression_call_cfgs_preserve_opcodes
    nodes = [
      [Onibi::AST::Backreference.new(1, false), :match_backreference],
      [Onibi::AST::Conditional.new(1, sequence("a"), sequence("b")), :match_conditional],
      [Onibi::AST::SubexpressionCall.new(1, false), :match_subexpression_call]
    ]

    nodes.each do |node, opcode|
      tnfa, dfa = automata_for(node)

      assert_equal [[0, opcode, node]], position_signature(tnfa), opcode
      assert_equal [[:start, 0, opcode, node]], transition_signature(tnfa), opcode
      assert_equal [[0, opcode, node, 1]], dfa_transition_signature(dfa), opcode
    end
  end

  def test_option_group_cfg_preserves_option_group_opcode_and_operand
    option_group = Onibi::AST::OptionGroup.new(sequence("a"), true, false, true)
    tnfa, dfa = automata_for(option_group)

    assert_equal [[0, :match_option_group, option_group]], position_signature(tnfa)
    assert_equal [[:start, 0, :match_option_group, option_group]], transition_signature(tnfa)
    assert_equal [[0, :match_option_group, option_group, 1]], dfa_transition_signature(dfa)
  end

  def test_partial_dfa_keeps_the_start_state_and_reports_truncation
    tnfa, full_dfa = automata_for(sequence("a", "b"))
    partial = Onibi::Automata::PartialDFA.from_tnfa(tnfa, state_limit: 2)

    assert_equal [0, 1], partial.states.map(&:id)
    assert_equal [[], [0]], partial.states.map(&:positions)
    assert_equal false, partial.states.any?(&:accepting)
    assert_equal({ [0, [:match_literal, Onibi::AST::Literal.new("a")]] => 1 }, partial.transitions)
    assert_equal true, partial.partial?
    assert_operator full_dfa.states.length, :>, partial.states.length
  end

  def test_cfg_converts_to_glushkov_tnfa_and_partial_dfa
    compiled = Onibi::Compiler.compile(Onibi::Parser.parse("a."))
    tnfa = Onibi::Automata::GlushkovTNFA.from_cfg(compiled.graph)

    assert_equal 1, tnfa.start_positions.length
    assert_equal 2, tnfa.positions.length
    assert_equal 1, tnfa.accept_positions.length

    dfa = Onibi::Automata::DFA.from_tnfa(tnfa)
    partial = Onibi::Automata::PartialDFA.from_tnfa(tnfa, state_limit: 1)
    assert_operator dfa.states.length, :>=, 2
    assert_equal true, partial.partial?
    assert_operator partial.states.length, :<=, 1
  end

  def test_tnfa_graph_has_expected_positions_and_opcodes
    compiled = Onibi::Compiler.compile(Onibi::Parser.parse("a."))
    tnfa = Onibi::Automata::GlushkovTNFA.from_cfg(compiled.graph)
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
    compiled = Onibi::Compiler.compile(Onibi::Parser.parse("a|b"))
    tnfa = Onibi::Automata::GlushkovTNFA.from_cfg(compiled.graph)

    assert_equal [0, 1], tnfa.start_positions
    assert_equal [0, 1], tnfa.accept_positions
    dfa = Onibi::Automata::DFA.from_tnfa(tnfa)
    assert_equal [], dfa.start_state.positions
    assert_equal [[0], [1]], dfa.states.drop(1).map(&:positions)
  end

  def test_dfa_transition_targets_are_state_ids
    compiled = Onibi::Compiler.compile(Onibi::Parser.parse("a."))
    tnfa = Onibi::Automata::GlushkovTNFA.from_cfg(compiled.graph)
    dfa = Onibi::Automata::DFA.from_tnfa(tnfa)

    assert(dfa.transitions.values.all? { |target| target.is_a?(Integer) })
  end

  private

  def automata_for(node)
    compiled = Onibi::Compiler.compile(node, passes: [:pure_failure_memoization])
    tnfa = Onibi::Automata::GlushkovTNFA.from_cfg(compiled.graph)
    [tnfa, Onibi::Automata::DFA.from_tnfa(tnfa)]
  end

  def sequence(*values)
    parts = values.map { |value| value.is_a?(String) ? Onibi::AST::Literal.new(value) : value }
    Onibi::AST::Sequence.new(parts)
  end

  def position_signature(tnfa)
    tnfa.positions.map { |position| [position.id, position.operation.opcode, position.operation.operand] }
  end

  def transition_signature(tnfa)
    tnfa.transitions.map do |edge|
      [edge.from, edge.to, edge.operation.opcode, edge.operation.operand]
    end
  end

  def state_signature(dfa)
    dfa.states.map { |state| [state.id, state.positions, state.accepting] }
  end

  def dfa_transition_signature(dfa)
    dfa.transitions.map do |(from, (opcode, operand)), to|
      [from, opcode, operand, to]
    end
  end
end
