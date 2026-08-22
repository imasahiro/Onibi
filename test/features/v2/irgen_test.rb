# frozen_string_literal: true

require "test_helper"
require "digest"

class V2IRGenTest < Minitest::Test
  BYTECODE_DIGESTS = {
    literal: "0dc60ad6f17cc967df0a1b6fbc6db9d2928d33569a2df8cecf060a827e3f81f8",
    character_class: "0dc60ad6f17cc967df0a1b6fbc6db9d2928d33569a2df8cecf060a827e3f81f8",
    escape: "16407935ddc5a7500473755721be613a816d2bcfec0195e4513b2fd86a25a813",
    property: "4743e71bcb818ed6c28096a196211d467f956fefdf08addf437d92e4ac00f922",
    any: "0dc60ad6f17cc967df0a1b6fbc6db9d2928d33569a2df8cecf060a827e3f81f8",
    sequence: "490f91ba8e8cbbbfc4ac0ecccc44f3ac47569e271347676f7b38893d1b5b926c",
    choice: "55689aaef0ccac3be77fee9fd6aedd9f4ddebb44aa6120a13b8f27f80d52f21d",
    repeat: "0609f8690e19784d2a7c48792fa19b9f3881b28f69d2473b0736aa2e92ee3a2c",
    capture: "95f22fd57fef22ef5aab0f7722b463026244e9269102cd6deff5a2499f495737",
    atomic: "f68fd93065765c9e459a8d53df392c4d2ce9c0b1dfb7b10d594a83c319838218",
    assertion: "9a8fad979931f5ee58676165fb0d04b1127133918caec5898b507b6d56555066",
    anchor: "16407935ddc5a7500473755721be613a816d2bcfec0195e4513b2fd86a25a813",
    absence: "2213f5591d9fb567cf9a43568b48605888de6251d196d79d78cf90b0898311ca",
    backreference: "16407935ddc5a7500473755721be613a816d2bcfec0195e4513b2fd86a25a813",
    conditional: "92689bb8486959c9bb61116134868ec54cc71231469c29ee091bc08b17a0a02e",
    subexpression: "16407935ddc5a7500473755721be613a816d2bcfec0195e4513b2fd86a25a813",
    option_group: "ebaaede0017448ffd7e3c4b8bf9d106b7a2ac36f4c5e2fd9ebcfc811a84ca09b",
    partial: "0dc60ad6f17cc967df0a1b6fbc6db9d2928d33569a2df8cecf060a827e3f81f8"
  }.freeze

  def test_literal_generates_real_yarv_iseq_and_matches_literal
    literal = Onibi::AST::Literal.new("a")
    iseq = generate(literal)

    assert_yarv_iseq(iseq)
    assert_includes disassembly(iseq), "label_match?"
    assert_includes disassembly(iseq), ":match_literal"
    assert_bytecode_digest iseq, :literal
    assert_equal true, iseq.eval.call("a")
    assert_equal false, iseq.eval.call("b")
  end

  def test_character_class_generates_class_label_in_yarv_iseq
    character_class = Onibi::AST::CharacterClass.new("a-z")
    iseq = generate(character_class)

    assert_yarv_iseq(iseq)
    assert_includes disassembly(iseq), ":match_class"
    assert_includes disassembly(iseq), "label_width"
    assert_bytecode_digest iseq, :character_class
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
      assert_bytecode_digest iseq, feature_for(node)
    end
  end

  def test_sequence_generates_ordered_yarv_match_and_state_update_code
    iseq = generate(sequence("a", "b"))
    output = disassembly(iseq)

    assert_yarv_iseq(iseq)
    assert_operator output.scan(":match_literal").length, :>=, 2
    assert_operator output.scan("label_width").length, :>=, 2
    assert_operator output.scan("setlocal").length, :>=, 2
    assert_bytecode_digest iseq, :sequence
    assert_equal true, iseq.eval.call("ab")
    assert_equal false, iseq.eval.call("a")
  end

  def test_choice_generates_yarv_case_dispatch_and_two_literal_paths
    iseq = generate(Onibi::AST::Alternation.new([sequence("a"), sequence("b")]))
    output = disassembly(iseq)

    assert_yarv_iseq(iseq)
    assert_includes output, "opt_case_dispatch"
    assert_operator output.scan(":match_literal").length, :>=, 2
    assert_bytecode_digest iseq, :choice
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
    assert_bytecode_digest iseq, :repeat
    assert_equal true, iseq.eval.call("a")
  end

  def test_capture_generates_group_operand_in_real_yarv_bytecode
    group = Onibi::AST::Group.new(sequence("a"), 1, true, "name")
    iseq = generate(group)

    assert_yarv_iseq(iseq)
    assert_includes disassembly(iseq), ":match_group"
    assert_includes disassembly(iseq), "capture"
    assert_includes disassembly(iseq), "name"
    assert_bytecode_digest iseq, :capture
  end

  def test_atomic_group_generates_atomic_group_operand_in_real_yarv_bytecode
    atomic = Onibi::AST::AtomicGroup.new(sequence("a", "b"))
    iseq = generate(atomic)

    assert_yarv_iseq(iseq)
    assert_includes disassembly(iseq), ":match_atomic_group"
    assert_includes disassembly(iseq), "Onibi::AST::AtomicGroup"
    assert_bytecode_digest iseq, :atomic
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
      assert_bytecode_digest iseq, feature_for(node)
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
      assert_bytecode_digest iseq, feature_for(node)
    end
  end

  def test_option_group_generates_option_group_yarv_label
    option_group = Onibi::AST::OptionGroup.new(sequence("a"), true, false, true)
    iseq = generate(option_group)

    assert_yarv_iseq(iseq)
    assert_includes disassembly(iseq), ":match_option_group"
    assert_includes disassembly(iseq), ":ignorecase"
    assert_bytecode_digest iseq, :option_group
  end

  def test_partial_dfa_generates_a_real_bounded_yarv_iseq
    tnfa = tnfa_for(sequence("a", "b"))
    dfa = Onibi::V2::Automata::PartialDFA.from_tnfa(tnfa, state_limit: 2)
    iseq = Onibi::V2::IRGen::YARVIR.generate_iseq(dfa)

    assert_yarv_iseq(iseq)
    assert_includes disassembly(iseq), ":match_literal"
    assert_bytecode_digest iseq, :partial
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

  def assert_bytecode_digest(iseq, feature)
    bytecode = disassembly(iseq).lines.filter_map do |line|
      line.match(/^\|?\s*\d+\s+([A-Za-z0-9_]+)/)&.captures&.first
    end.join(",")
    assert_equal BYTECODE_DIGESTS.fetch(feature), Digest::SHA256.hexdigest(bytecode), feature.to_s
  end

  def feature_for(node)
    {
      Onibi::AST::Escape => :escape,
      Onibi::AST::Property => :property,
      Onibi::AST::Any => :any,
      Onibi::AST::Assertion => :assertion,
      Onibi::AST::Anchor => :anchor,
      Onibi::AST::Absence => :absence,
      Onibi::AST::Backreference => :backreference,
      Onibi::AST::Conditional => :conditional,
      Onibi::AST::SubexpressionCall => :subexpression
    }.fetch(node.class)
  end

  def assert_yarv_iseq(iseq)
    assert_instance_of RubyVM::InstructionSequence, iseq
    assert_equal "YARVInstructionSequence/SimpleDataFormat", iseq.to_a.first
    assert_includes disassembly(iseq), "label_match?"
    assert_includes disassembly(iseq), "branchunless"
  end
end
