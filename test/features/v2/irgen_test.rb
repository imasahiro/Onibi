# frozen_string_literal: true

require "test_helper"

class V2IRGenTest < Minitest::Test
  def test_literal_generates_exact_instruction_stream
    literal = Onibi::AST::Literal.new("a")
    assert_equal [
      [:start, 0], [:match, [:match_literal, literal]], [:jump, 1], [:accept, 1]
    ], instruction_signature(program_for(literal))
  end

  def test_nfa_and_dfa_modes_generate_different_code_for_a_literal
    literal = Onibi::AST::Literal.new("a")
    tnfa = tnfa_for(literal)
    dfa = Onibi::Automata::DFA.from_tnfa(tnfa)

    assert_equal [
      [:nfa_start, [0]],
      [:nfa_match, [:start, 0, [:match_literal, literal]]],
      [:nfa_accept, [0]]
    ], instruction_signature(Onibi::IRGen::YARVIR.generate(tnfa, mode: :nfa))
    assert_equal [
      [:start, 0], [:match, [:match_literal, literal]], [:jump, 1], [:accept, 1]
    ], instruction_signature(Onibi::IRGen::YARVIR.generate(dfa, mode: :dfa))
  end

  def test_nfa_mode_keeps_choice_edges_while_dfa_mode_merges_them_into_states
    ast = Onibi::AST::Alternation.new([sequence("a"), sequence("b")])
    tnfa = tnfa_for(ast)
    dfa = Onibi::Automata::DFA.from_tnfa(tnfa)
    nfa_instructions = instruction_signature(Onibi::IRGen::YARVIR.generate(tnfa, mode: :nfa))
    dfa_instructions = instruction_signature(Onibi::IRGen::YARVIR.generate(dfa, mode: :dfa))

    assert_equal :nfa_start, nfa_instructions.first.first
    assert_equal [0, 1], nfa_instructions.first.last
    nfa_match_count = nfa_instructions.count { |opcode, _operand| opcode == :nfa_match }
    dfa_match_count = dfa_instructions.count { |opcode, _operand| opcode == :match }
    assert_equal 2, nfa_match_count
    assert_equal 2, dfa_match_count
    assert_equal %i[start match jump match jump accept accept], dfa_instructions.map(&:first)
    refute_equal nfa_instructions, dfa_instructions
  end

  def test_character_class_generates_exact_instruction_stream
    node = Onibi::AST::CharacterClass.new("a-z")
    assert_equal [
      [:start, 0], [:match, [:match_class, node]], [:jump, 1], [:accept, 1]
    ], instruction_signature(program_for(node))
  end

  def test_escape_property_and_any_generate_exact_match_operands
    nodes = [
      [Onibi::AST::Escape.new(:digit), :match_escape],
      [Onibi::AST::Property.new("Alpha", false), :match_property],
      [Onibi::AST::Any.new("."), :match_any]
    ]
    nodes.each do |node, opcode|
      assert_equal [
        [:start, 0], [:match, [opcode, node]], [:jump, 1], [:accept, 1]
      ], instruction_signature(program_for(node)), opcode
    end
  end

  def test_sequence_generates_ordered_match_and_jump_instructions
    ast = sequence("a", "b")
    literal_a, literal_b = ast.parts
    assert_equal [
      [:start, 0], [:match, [:match_literal, literal_a]], [:jump, 1],
      [:match, [:match_literal, literal_b]], [:jump, 2], [:accept, 2]
    ], instruction_signature(program_for(ast))
  end

  def test_choice_generates_all_match_paths_and_accept_states
    ast = Onibi::AST::Alternation.new([sequence("a"), sequence("b")])
    literal_a = ast.branches[0].parts.first
    literal_b = ast.branches[1].parts.first
    assert_equal [
      [:start, 0], [:match, [:match_literal, literal_a]], [:jump, 1],
      [:match, [:match_literal, literal_b]], [:jump, 2],
      [:accept, 1], [:accept, 2]
    ], instruction_signature(program_for(ast))
  end

  def test_repeat_generates_exact_quantifier_operand
    node = Onibi::AST::Quantifier.new(Onibi::AST::Literal.new("a"), :+, 1, nil, :greedy)
    assert_equal [
      [:start, 0], [:match, [:match_quantifier, node]], [:jump, 1], [:accept, 1]
    ], instruction_signature(program_for(node))
  end

  def test_capture_generates_exact_group_operand
    node = Onibi::AST::Group.new(sequence("a"), 1, true, "name")
    assert_equal [
      [:start, 0], [:match, [:match_group, node]], [:jump, 1], [:accept, 1]
    ], instruction_signature(program_for(node))
  end

  def test_atomic_group_generates_exact_atomic_operand
    node = Onibi::AST::AtomicGroup.new(sequence("a", "b"))
    assert_equal [
      [:start, 0], [:match, [:match_atomic_group, node]], [:jump, 1], [:accept, 1]
    ], instruction_signature(program_for(node))
  end

  def test_assertion_anchor_and_absence_generate_exact_operands
    nodes = [
      [Onibi::AST::Assertion.new(sequence("a"), :positive), :match_assertion],
      [Onibi::AST::Anchor.new(:anchor_start), :test_anchor],
      [Onibi::AST::Absence.new(sequence("a")), :match_absence]
    ]
    nodes.each do |node, opcode|
      assert_equal [
        [:start, 0], [:match, [opcode, node]], [:jump, 1], [:accept, 1]
      ], instruction_signature(program_for(node)), opcode
    end
  end

  def test_backreference_conditional_and_subexpression_call_generate_exact_operands
    nodes = [
      [Onibi::AST::Backreference.new(1, false), :match_backreference],
      [Onibi::AST::Conditional.new(1, sequence("a"), sequence("b")), :match_conditional],
      [Onibi::AST::SubexpressionCall.new(1, false), :match_subexpression_call]
    ]
    nodes.each do |node, opcode|
      assert_equal [
        [:start, 0], [:match, [opcode, node]], [:jump, 1], [:accept, 1]
      ], instruction_signature(program_for(node)), opcode
    end
  end

  def test_option_group_generates_exact_option_operand
    node = Onibi::AST::OptionGroup.new(sequence("a"), true, false, true)
    assert_equal [
      [:start, 0], [:match, [:match_option_group, node]], [:jump, 1], [:accept, 1]
    ], instruction_signature(program_for(node))
  end

  def test_partial_dfa_generates_only_available_states
    partial = Onibi::Automata::PartialDFA.from_tnfa(tnfa_for(sequence("a", "b")), state_limit: 2)
    assert_equal [
      [:start, 0], [:match, [:match_literal, Onibi::AST::Literal.new("a")]], [:jump, 1]
    ], instruction_signature(Onibi::IRGen::YARVIR.generate_iseq(partial))
  end

  def test_dfa_lowers_to_dedicated_onibi_bytecode
    cfg = Onibi::Compiler.compile(Onibi::Parser.parse("a")).graph
    dfa = Onibi::Automata::DFA.from_tnfa(Onibi::Automata::GlushkovTNFA.from_cfg(cfg))
    program = Onibi::IRGen::YARVIR.generate(dfa)
    assert_instance_of Onibi::IRGen::YARVIR::Program, program
    assert_same program, program.iseq
    assert_equal :start, program.instructions.first.opcode
    assert_equal :accept, program.instructions.last.opcode
    assert_equal [[:match_literal, Onibi::AST::Literal.new("a")]],
                 program.instructions.select { |instruction| instruction.opcode == :match }.map(&:operand)
  end

  def test_dedicated_executor_matches_literal_without_mri_regexp
    cfg = Onibi::Compiler.compile(Onibi::Parser.parse("cat")).graph
    dfa = Onibi::Automata::DFA.from_tnfa(Onibi::Automata::GlushkovTNFA.from_cfg(cfg))
    program = Onibi::IRGen::YARVIR.generate(dfa)

    assert_equal [2, 5], Onibi::IRGen::YARVIR.execute(program, "xxcatyy", 0)
    assert_nil Onibi::IRGen::YARVIR.execute(program, "xxdogyy", 0)
  end

  def test_dedicated_executor_consumes_a_quantifier_run
    cfg = Onibi::Compiler.compile(Onibi::Parser.parse("a+")).graph
    dfa = Onibi::Automata::DFA.from_tnfa(Onibi::Automata::GlushkovTNFA.from_cfg(cfg))
    program = Onibi::IRGen::YARVIR.generate(dfa)

    assert_equal [2, 5], Onibi::IRGen::YARVIR.execute(program, "xxaaaby", 0)
  end

  def test_dedicated_executor_handles_literal_absence
    cfg = Onibi::Compiler.compile(Onibi::Parser.parse("(?~END)")).graph
    dfa = Onibi::Automata::DFA.from_tnfa(Onibi::Automata::GlushkovTNFA.from_cfg(cfg))
    program = Onibi::IRGen::YARVIR.generate(dfa)

    assert_equal [0, 4], Onibi::IRGen::YARVIR.execute(program, "xxENDyy", 0)
  end

  def test_dedicated_executor_evaluates_zero_width_assertions
    cfg = Onibi::Compiler.compile(Onibi::Parser.parse("a(?=b)")).graph
    dfa = Onibi::Automata::DFA.from_tnfa(Onibi::Automata::GlushkovTNFA.from_cfg(cfg))
    program = Onibi::IRGen::YARVIR.generate(dfa)

    assert_equal [2, 3], Onibi::IRGen::YARVIR.execute(program, "xxabyy", 0)
    assert_nil Onibi::IRGen::YARVIR.execute(program, "xxacyy", 0)
  end

  def test_ir_contains_state_id_jump_for_each_dfa_edge
    cfg = Onibi::Compiler.compile(Onibi::Parser.parse("a.")).graph
    dfa = Onibi::Automata::DFA.from_tnfa(Onibi::Automata::GlushkovTNFA.from_cfg(cfg))
    jumps = Onibi::IRGen::YARVIR.generate(dfa).instructions.select { |instruction| instruction.opcode == :jump }
    assert_equal [1, 2], jumps.map(&:operand)
  end

  def test_iseq_matches_the_complete_expected_instruction_stream
    cfg = Onibi::Compiler.compile(Onibi::Parser.parse("a.")).graph
    dfa = Onibi::Automata::DFA.from_tnfa(Onibi::Automata::GlushkovTNFA.from_cfg(cfg))
    program = Onibi::IRGen::YARVIR.generate(dfa)
    expected = [
      [:start, 0], [:match, [:match_literal, Onibi::AST::Literal.new("a")]], [:jump, 1],
      [:match, [:match_any, Onibi::AST::Any.new(".")]], [:jump, 2], [:accept, 2]
    ]
    assert_equal expected, instruction_signature(program)
  end

  private

  def program_for(node)
    dfa = Onibi::Automata::DFA.from_tnfa(tnfa_for(node))
    Onibi::IRGen::YARVIR.generate(dfa)
  end

  def tnfa_for(node)
    compiled = Onibi::Compiler.compile(node, passes: [:pure_failure_memoization])
    Onibi::Automata::GlushkovTNFA.from_cfg(compiled.graph)
  end

  def sequence(*values)
    parts = values.map { |value| value.is_a?(String) ? Onibi::AST::Literal.new(value) : value }
    Onibi::AST::Sequence.new(parts)
  end

  def instruction_signature(program)
    program.instructions.map { |instruction| [instruction.opcode, instruction.operand] }
  end
end
