# frozen_string_literal: true

require "test_helper"

class V2IRGenTest < Minitest::Test
  def test_literal_generates_real_yarv_iseq_and_matches_literal
    literal = Onibi::AST::Literal.new("a")
    iseq = generate(literal)

    assert_yarv_iseq(iseq)
    assert_includes disassembly(iseq), "label_match?"
    assert_includes disassembly(iseq), ":match_literal"
    assert_equal true, iseq.eval.call("a")
    assert_equal false, iseq.eval.call("b")
  end

  def test_character_class_generates_class_label_in_yarv_iseq
    character_class = Onibi::AST::CharacterClass.new("a-z")
    iseq = generate(character_class)

    assert_yarv_iseq(iseq)
    assert_includes disassembly(iseq), ":match_class"
    assert_includes disassembly(iseq), "label_width"
    assert_equal true, iseq.eval.call("x")
  end

  def test_escape_property_and_any_generate_distinct_yarv_match_labels
    nodes = [
      [Onibi::AST::Escape.new(:digit), ":match_escape"],
      [Onibi::AST::Property.new("Alpha", false), ":match_property"],
      [Onibi::AST::Any.new("."), ":match_any"]
    ]

    nodes.each do |node, opcode|
      iseq = generate(node)

      assert_yarv_iseq(iseq)
      assert_includes disassembly(iseq), opcode, opcode
      assert_includes disassembly(iseq), "branchunless", opcode
    end
  end

  def test_sequence_generates_ordered_yarv_match_and_state_update_code
    iseq = generate(sequence("a", "b"))
    output = disassembly(iseq)

    assert_yarv_iseq(iseq)
    assert_operator output.scan(":match_literal").length, :>=, 2
    assert_operator output.scan("label_width").length, :>=, 2
    assert_operator output.scan("setlocal").length, :>=, 2
    assert_equal true, iseq.eval.call("ab")
    assert_equal false, iseq.eval.call("a")
  end

  def test_choice_generates_yarv_case_dispatch_and_two_literal_paths
    iseq = generate(Onibi::AST::Alternation.new([sequence("a"), sequence("b")]))
    output = disassembly(iseq)

    assert_yarv_iseq(iseq)
    assert_includes output, "opt_case_dispatch"
    assert_operator output.scan(":match_literal").length, :>=, 2
    assert_equal true, iseq.eval.call("a")
    assert_equal true, iseq.eval.call("b")
    assert_equal false, iseq.eval.call("c")
  end

  def test_repeat_generates_quantifier_operand_in_real_yarv_bytecode
    quantifier = Onibi::AST::Quantifier.new(Onibi::AST::Literal.new("a"), :+, 1, nil, :greedy)
    iseq = generate(quantifier)

    assert_yarv_iseq(iseq)
    assert_includes disassembly(iseq), ":match_quantifier"
    assert_includes disassembly(iseq), ":minimum"
    assert_equal true, iseq.eval.call("a")
  end

  def test_capture_generates_group_operand_in_real_yarv_bytecode
    group = Onibi::AST::Group.new(sequence("a"), 1, true, "name")
    iseq = generate(group)

    assert_yarv_iseq(iseq)
    assert_includes disassembly(iseq), ":match_group"
    assert_includes disassembly(iseq), "capture"
    assert_includes disassembly(iseq), "name"
  end

  def test_atomic_group_generates_atomic_group_operand_in_real_yarv_bytecode
    atomic = Onibi::AST::AtomicGroup.new(sequence("a", "b"))
    iseq = generate(atomic)

    assert_yarv_iseq(iseq)
    assert_includes disassembly(iseq), ":match_atomic_group"
    assert_includes disassembly(iseq), "Onibi::AST::AtomicGroup"
  end

  def test_assertion_anchor_and_absence_generate_semantic_yarv_labels
    nodes = [
      [Onibi::AST::Assertion.new(sequence("a"), :positive), ":match_assertion"],
      [Onibi::AST::Anchor.new(:anchor_start), ":test_anchor"],
      [Onibi::AST::Absence.new(sequence("a")), ":match_absence"]
    ]

    nodes.each do |node, opcode|
      iseq = generate(node)

      assert_yarv_iseq(iseq)
      assert_includes disassembly(iseq), opcode, opcode
      assert_includes disassembly(iseq), "label_match?", opcode
    end
  end

  def test_backreference_conditional_and_subexpression_call_generate_yarv_labels
    nodes = [
      [Onibi::AST::Backreference.new(1, false), ":match_backreference"],
      [Onibi::AST::Conditional.new(1, sequence("a"), sequence("b")), ":match_conditional"],
      [Onibi::AST::SubexpressionCall.new(1, false), ":match_subexpression_call"]
    ]

    nodes.each do |node, opcode|
      iseq = generate(node)

      assert_yarv_iseq(iseq)
      assert_includes disassembly(iseq), opcode, opcode
    end
  end

  def test_option_group_generates_option_group_yarv_label
    option_group = Onibi::AST::OptionGroup.new(sequence("a"), true, false, true)
    iseq = generate(option_group)

    assert_yarv_iseq(iseq)
    assert_includes disassembly(iseq), ":match_option_group"
    assert_includes disassembly(iseq), ":ignorecase"
  end

  def test_partial_dfa_generates_a_real_bounded_yarv_iseq
    tnfa = tnfa_for(sequence("a", "b"))
    dfa = Onibi::V2::Automata::PartialDFA.from_tnfa(tnfa, state_limit: 2)
    iseq = Onibi::V2::IRGen::YARVIR.generate_iseq(dfa)

    assert_yarv_iseq(iseq)
    assert_includes disassembly(iseq), ":match_literal"
    assert_equal false, iseq.eval.call("a")
    assert_equal false, iseq.eval.call("ab")
  end

  private

  def generate(node)
    dfa = Onibi::V2::Automata::DFA.from_tnfa(tnfa_for(node))
    Onibi::V2::IRGen::YARVIR.generate_iseq(dfa)
  end

  def tnfa_for(node)
    compiled = Onibi::V2::Compiler.compile(node, passes: [:pure_failure_memoization])
    Onibi::V2::Automata::GlushkovTNFA.from_cfg(compiled.graph)
  end

  def sequence(*values)
    parts = values.map { |value| value.is_a?(String) ? Onibi::AST::Literal.new(value) : value }
    Onibi::AST::Sequence.new(parts)
  end

  def disassembly(iseq)
    RubyVM::InstructionSequence.disasm(iseq)
  end

  def assert_yarv_iseq(iseq)
    assert_instance_of RubyVM::InstructionSequence, iseq
    assert_equal "YARVInstructionSequence/SimpleDataFormat", iseq.to_a.first
    assert_includes disassembly(iseq), "label_match?"
    assert_includes disassembly(iseq), "branchunless"
  end
end
