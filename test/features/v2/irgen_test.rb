# frozen_string_literal: true

require "test_helper"

class V2IRGenTest < Minitest::Test
  def test_literal_generates_exact_start_match_jump_and_accept_iseq
    literal = Onibi::AST::Literal.new("a")

    assert_equal [
      [:start, 0],
      [:match, [:match_literal, literal]],
      [:jump, 1],
      [:accept, 1]
    ], instruction_signature(program_for(literal))
  end

  def test_character_class_generates_class_match_opcode
    character_class = Onibi::AST::CharacterClass.new("a-z")

    assert_equal [
      [:start, 0],
      [:match, [:match_class, character_class]],
      [:jump, 1],
      [:accept, 1]
    ], instruction_signature(program_for(character_class))
  end

  def test_escape_property_and_any_generate_their_match_opcodes
    nodes = [
      [Onibi::AST::Escape.new(:digit), :match_escape],
      [Onibi::AST::Property.new("Alpha", false), :match_property],
      [Onibi::AST::Any.new("."), :match_any]
    ]

    nodes.each do |node, opcode|
      assert_equal [
        [:start, 0],
        [:match, [opcode, node]],
        [:jump, 1],
        [:accept, 1]
      ], instruction_signature(program_for(node)), opcode
    end
  end

  def test_sequence_generates_ordered_match_and_jump_instructions
    ast = sequence("a", "b")
    literal_a, literal_b = ast.parts

    assert_equal [
      [:start, 0],
      [:match, [:match_literal, literal_a]],
      [:jump, 1],
      [:match, [:match_literal, literal_b]],
      [:jump, 2],
      [:accept, 2]
    ], instruction_signature(program_for(ast))
  end

  def test_choice_generates_one_match_path_and_accept_for_each_branch
    ast = Onibi::AST::Alternation.new([sequence("a"), sequence("b")])
    literal_a = ast.branches[0].parts.first
    literal_b = ast.branches[1].parts.first

    assert_equal [
      [:start, 0],
      [:match, [:match_literal, literal_a]],
      [:jump, 1],
      [:match, [:match_literal, literal_b]],
      [:jump, 2],
      [:accept, 1],
      [:accept, 2]
    ], instruction_signature(program_for(ast))
  end

  def test_repeat_generates_quantifier_match_opcode_and_accept
    quantifier = Onibi::AST::Quantifier.new(Onibi::AST::Literal.new("a"), :+, 1, nil, :greedy)

    assert_equal [
      [:start, 0],
      [:match, [:match_quantifier, quantifier]],
      [:jump, 1],
      [:accept, 1]
    ], instruction_signature(program_for(quantifier))
  end

  def test_capture_generates_group_match_with_capture_metadata
    group = Onibi::AST::Group.new(sequence("a"), 1, true, "name")

    assert_equal [
      [:start, 0],
      [:match, [:match_group, group]],
      [:jump, 1],
      [:accept, 1]
    ], instruction_signature(program_for(group))
  end

  def test_atomic_group_generates_atomic_match_opcode
    atomic = Onibi::AST::AtomicGroup.new(sequence("a", "b"))

    assert_equal [
      [:start, 0],
      [:match, [:match_atomic_group, atomic]],
      [:jump, 1],
      [:accept, 1]
    ], instruction_signature(program_for(atomic))
  end

  def test_assertion_anchor_and_absence_generate_semantic_match_opcodes
    nodes = [
      [Onibi::AST::Assertion.new(sequence("a"), :positive), :match_assertion],
      [Onibi::AST::Anchor.new(:anchor_start), :test_anchor],
      [Onibi::AST::Absence.new(sequence("a")), :match_absence]
    ]

    nodes.each do |node, opcode|
      assert_equal [
        [:start, 0],
        [:match, [opcode, node]],
        [:jump, 1],
        [:accept, 1]
      ], instruction_signature(program_for(node)), opcode
    end
  end

  def test_backreference_conditional_and_subexpression_call_generate_opcodes
    nodes = [
      [Onibi::AST::Backreference.new(1, false), :match_backreference],
      [Onibi::AST::Conditional.new(1, sequence("a"), sequence("b")), :match_conditional],
      [Onibi::AST::SubexpressionCall.new(1, false), :match_subexpression_call]
    ]

    nodes.each do |node, opcode|
      assert_equal [
        [:start, 0],
        [:match, [opcode, node]],
        [:jump, 1],
        [:accept, 1]
      ], instruction_signature(program_for(node)), opcode
    end
  end

  def test_option_group_generates_option_group_match_opcode
    option_group = Onibi::AST::OptionGroup.new(sequence("a"), true, false, true)

    assert_equal [
      [:start, 0],
      [:match, [:match_option_group, option_group]],
      [:jump, 1],
      [:accept, 1]
    ], instruction_signature(program_for(option_group))
  end

  def test_partial_dfa_generates_only_the_available_iseq_states
    tnfa = tnfa_for(sequence("a", "b"))
    partial = Onibi::V2::Automata::PartialDFA.from_tnfa(tnfa, state_limit: 2)

    assert_equal [
      [:start, 0],
      [:match, [:match_literal, Onibi::AST::Literal.new("a")]],
      [:jump, 1]
    ], instruction_signature(Onibi::V2::IRGen::YARVIR.generate_iseq(partial))
  end

  def test_dfa_lowers_to_yarv_ir
    parsed = Onibi::V2::Parser.parse("a")
    cfg = Onibi::V2::Compiler.compile(parsed).graph
    tnfa = Onibi::V2::Automata::GlushkovTNFA.from_cfg(cfg)
    dfa = Onibi::V2::Automata::DFA.from_tnfa(tnfa)
    program = Onibi::V2::IRGen::YARVIR.generate(dfa)

    assert_instance_of Onibi::V2::IRGen::YARVIR::Program, program
    assert_same program, program.iseq
    assert_equal :start, program.instructions.first.opcode
    assert_includes program.instructions.map(&:opcode), :match
    assert_equal :accept, program.instructions.last.opcode
    match_operands = program.instructions.select { |instruction| instruction.opcode == :match }.map(&:operand)
    assert_equal [[:match_literal, Onibi::AST::Literal.new("a")]], match_operands
  end

  def test_ir_contains_state_id_jump_for_dfa_edge
    parsed = Onibi::V2::Parser.parse("a.")
    cfg = Onibi::V2::Compiler.compile(parsed).graph
    tnfa = Onibi::V2::Automata::GlushkovTNFA.from_cfg(cfg)
    dfa = Onibi::V2::Automata::DFA.from_tnfa(tnfa)
    program = Onibi::V2::IRGen::YARVIR.generate(dfa)

    jumps = program.instructions.select { |instruction| instruction.opcode == :jump }
    assert_equal [1, 2], jumps.map(&:operand)
  end

  def test_iseq_matches_the_expected_instruction_stream
    cfg = Onibi::V2::Compiler.compile(Onibi::V2::Parser.parse("a.")).graph
    dfa = Onibi::V2::Automata::DFA.from_tnfa(Onibi::V2::Automata::GlushkovTNFA.from_cfg(cfg))
    program = Onibi::V2::IRGen::YARVIR.generate(dfa)
    expected = [
      [:start, 0],
      [:match, [:match_literal, Onibi::AST::Literal.new("a")]],
      [:jump, 1],
      [:match, [:match_any, Onibi::AST::Any.new(".")]],
      [:jump, 2],
      [:accept, 2]
    ]

    assert_equal(expected, program.instructions.map { |instruction| [instruction.opcode, instruction.operand] })
  end

  private

  def program_for(node)
    dfa = Onibi::V2::Automata::DFA.from_tnfa(tnfa_for(node))
    Onibi::V2::IRGen::YARVIR.generate(dfa)
  end

  def tnfa_for(node)
    compiled = Onibi::V2::Compiler.compile(node, passes: [:pure_failure_memoization])
    Onibi::V2::Automata::GlushkovTNFA.from_cfg(compiled.graph)
  end

  def sequence(*values)
    parts = values.map { |value| value.is_a?(String) ? Onibi::AST::Literal.new(value) : value }
    Onibi::AST::Sequence.new(parts)
  end

  def instruction_signature(program)
    program.instructions.map { |instruction| [instruction.opcode, instruction.operand] }
  end
end
