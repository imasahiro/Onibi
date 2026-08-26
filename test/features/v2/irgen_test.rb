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

  def test_semantic_bytecode_is_lowered_to_a_linear_program_operand
    root = Onibi::IRGen::YARVIR::SemanticBytecode.compile(
      Onibi::Parser.parse("(ab)+").ast
    )
    dfa = Onibi::Automata::DFA.from_tnfa(tnfa_for(Onibi::Parser.parse("(ab)+").ast))
    program = Onibi::IRGen::YARVIR.generate(
      dfa, semantic_root: root, flags: { retain_semantic_tree: true }
    )
    instruction = program.instructions.find { |item| item.opcode == :semantic_match }

    assert_instance_of Onibi::IRGen::YARVIR::SemanticBytecode::SemanticProgram, instruction.operand
    assert_equal 0, instruction.operand.entry
    assert_operator instruction.operand.instructions.length, :>, 1
    assert_equal root, instruction.operand.entry_node
    refute program.tree_free?
  end

  def test_flat_safe_semantic_root_does_not_retain_tree_by_default
    root = Onibi::IRGen::YARVIR::SemanticBytecode.compile(
      Onibi::Parser.parse("(ab)+").ast
    )
    dfa = Onibi::Automata::DFA.from_tnfa(tnfa_for(Onibi::Parser.parse("(ab)+").ast))
    program = Onibi::IRGen::YARVIR.generate(dfa, semantic_root: root)

    refute(program.instructions.any? { |item| item.opcode == :semantic_match })
    assert(program.instructions.any? { |item| item.opcode == :semantic_flat })
  end

  def test_semantic_program_exposes_flat_vm_commands
    root = Onibi::IRGen::YARVIR::SemanticBytecode.compile(
      Onibi::Parser.parse("(?<x>a|b)+\\1").ast
    )
    commands = Onibi::IRGen::YARVIR::SemanticBytecode.lower(root).vm_instructions

    assert_includes commands.map(&:opcode), :choice
    assert_includes commands.map(&:opcode), :repeat
    assert_includes commands.map(&:opcode), :capture
    assert_includes commands.map(&:opcode), :backreference
    assert(commands.all? { |command| command.operand.is_a?(Integer) })
  end

  def test_flat_compiler_emits_specialized_leaf_opcodes
    regexp = Onibi::Regexp.new("[a-z]\\d.")
    flat = regexp.send(:bytecode_program).instructions.find { |item| item.opcode == :semantic_flat }.operand

    assert_includes flat.instructions.map(&:opcode), :consume_class
    assert_includes flat.instructions.map(&:opcode), :consume_escape
    assert_includes flat.instructions.map(&:opcode), :consume_any
  end

  def test_flat_program_does_not_embed_legacy_semantic_command_stream
    program = Onibi::Regexp.new("(a|b)").send(:bytecode_program)
    flat = program.instructions.find { |item| item.opcode == :semantic_flat }.operand

    assert(program.instructions.any? { |item| item.opcode == :semantic_flat })
    refute(program.instructions.any? { |item| item.opcode == :semantic_vm })
    assert flat.tree_free?
    assert(flat.operands.grep(Onibi::IRGen::YARVIR::SemanticBytecode::Sequence).all? { |node| node.parts.empty? })
    assert(flat.operands.grep(Onibi::IRGen::YARVIR::SemanticBytecode::Alternation).all? { |node| node.branches.empty? })
  end

  def test_flat_program_rejects_invalid_subroutine_target
    assert_raises(ArgumentError) do
      Onibi::IRGen::YARVIR::SemanticBytecode::FlatProgram.new(
        instructions: [Onibi::IRGen::YARVIR::SemanticBytecode::VMInstruction.new(opcode: :accept)],
        subroutines: { 1 => 2 }
      )
    end
  end

  def test_flat_program_accepts_fold_boundary_instruction
    instruction = Onibi::IRGen::YARVIR::SemanticBytecode::VMInstruction.new(
      opcode: :fold_boundary, operand: 0
    )
    flat = Onibi::IRGen::YARVIR::SemanticBytecode::FlatProgram.new(
      instructions: [instruction, Onibi::IRGen::YARVIR::SemanticBytecode::VMInstruction.new(opcode: :accept)],
      operands: [Onibi::IRGen::YARVIR::SemanticBytecode::Literal.new("ſ", "s", [["ſ", "s"]], true)]
    )

    assert_equal :fold_boundary, flat.opcode_at(0)
  end

  def test_flat_program_exposes_verified_subroutine_target_lookup
    flat = Onibi::Regexp.new("(?<x>a)\\g<x>").send(:bytecode_program).instructions
                        .find { |instruction| instruction.opcode == :semantic_flat }.operand

    assert_equal flat.subroutines.fetch(1), flat.call_target(1)
    assert_equal flat.subroutines.fetch("x"), flat.call_target("x")
    assert_equal :capture_start, flat.instruction_at(flat.subroutines.fetch(1)).opcode
    assert flat.valid_pc?(flat.entry)
    refute flat.valid_pc?(flat.instructions.length)
    assert_equal :capture_start, flat.opcode_at(flat.subroutines.fetch(1))
  end

  def test_flat_program_rejects_invalid_control_flow_target
    instruction = Onibi::IRGen::YARVIR::SemanticBytecode::VMInstruction.new(opcode: :jump, target: 4)

    assert_raises(ArgumentError) do
      Onibi::IRGen::YARVIR::SemanticBytecode::FlatProgram.new(instructions: [instruction])
    end
  end

  def test_flat_program_rejects_invalid_fold_boundary_target
    instruction = Onibi::IRGen::YARVIR::SemanticBytecode::VMInstruction.new(
      opcode: :fold_boundary, target: 2
    )

    assert_raises(ArgumentError) do
      Onibi::IRGen::YARVIR::SemanticBytecode::FlatProgram.new(instructions: [instruction])
    end
  end

  def test_flat_program_rejects_backward_fold_boundary_target
    instruction = Onibi::IRGen::YARVIR::SemanticBytecode::VMInstruction.new(
      opcode: :fold_boundary, target: 0
    )

    assert_raises(ArgumentError) do
      Onibi::IRGen::YARVIR::SemanticBytecode::FlatProgram.new(
        instructions: [instruction, Onibi::IRGen::YARVIR::SemanticBytecode::VMInstruction.new(opcode: :accept)]
      )
    end
  end

  def test_flat_program_resolves_fold_boundary_target
    instructions = [
      Onibi::IRGen::YARVIR::SemanticBytecode::VMInstruction.new(opcode: :fold_boundary, operand: 0, target: 1),
      Onibi::IRGen::YARVIR::SemanticBytecode::VMInstruction.new(opcode: :consume, operand: 1),
      Onibi::IRGen::YARVIR::SemanticBytecode::VMInstruction.new(opcode: :accept)
    ]
    literal = Onibi::IRGen::YARVIR::SemanticBytecode::Literal.new(
      "ſ", "s", [["ſ", "s"]], true, { kind: :expanded_tail, tail: "ι", sensitive: true }
    )
    suffix = Onibi::IRGen::YARVIR::SemanticBytecode::Literal.new("ι", "ι")
    flat = Onibi::IRGen::YARVIR::SemanticBytecode::FlatProgram.new(
      instructions: instructions, operands: [literal, suffix]
    )

    assert_equal :consume, flat.boundary_target(0).opcode
    assert_nil flat.boundary_target(2)
    assert_equal({ operand: 0, next_pc: 1, literal: literal, casefold: "s",
                   boundary: { kind: :expanded_tail, tail: "ι", sensitive: true }, policy: nil,
                   next_literal: suffix, next_casefold: "ι", next_source_width: 1,
                   next_literals: [suffix], next_fold_width_deltas: [0], backedge_pcs: [] },
                  flat.boundary_metadata(0).to_h)
    metadata = flat.boundary_metadata(0)
    assert metadata.expanded_tail?
    assert metadata.tail_matches_next_fold?
    assert metadata.tail_matches_any_next_fold?
    assert_equal [0], metadata.matching_next_fold_indices
    assert metadata.matching_next_fold_width?(1)
    assert metadata.matching_next_fold_width_delta?(1, 0)
    refute metadata.repeat_backedge?
    assert_equal(0, metadata.fold_width_delta)
    assert_equal(0, metadata.next_fold_width_delta)
    assert metadata.source_width_match?(1)
    refute metadata.source_width_match?(2)
    assert metadata.next_source_width_match?(1)
    refute metadata.next_source_width_match?(2)
    assert_equal [0], metadata.next_fold_width_delta_candidates
  end

  def test_flat_program_resolves_fold_boundary_through_forward_jump
    instructions = [
      Onibi::IRGen::YARVIR::SemanticBytecode::VMInstruction.new(opcode: :fold_boundary, operand: 0, target: 1),
      Onibi::IRGen::YARVIR::SemanticBytecode::VMInstruction.new(opcode: :jump, target: 2),
      Onibi::IRGen::YARVIR::SemanticBytecode::VMInstruction.new(opcode: :consume, operand: 1),
      Onibi::IRGen::YARVIR::SemanticBytecode::VMInstruction.new(opcode: :accept)
    ]
    literal = Onibi::IRGen::YARVIR::SemanticBytecode::Literal.new("ᾀ", "ἀι")
    suffix = Onibi::IRGen::YARVIR::SemanticBytecode::Literal.new("a")
    flat = Onibi::IRGen::YARVIR::SemanticBytecode::FlatProgram.new(
      instructions: instructions, operands: [literal, suffix]
    )

    assert_equal suffix, flat.boundary_metadata(0).next_literal
  end

  def test_flat_program_resolves_fold_boundary_through_forward_split
    instructions = [
      Onibi::IRGen::YARVIR::SemanticBytecode::VMInstruction.new(opcode: :fold_boundary, operand: 0, target: 1),
      Onibi::IRGen::YARVIR::SemanticBytecode::VMInstruction.new(opcode: :split, target: [2, 3]),
      Onibi::IRGen::YARVIR::SemanticBytecode::VMInstruction.new(opcode: :consume, operand: 1),
      Onibi::IRGen::YARVIR::SemanticBytecode::VMInstruction.new(opcode: :consume, operand: 2),
      Onibi::IRGen::YARVIR::SemanticBytecode::VMInstruction.new(opcode: :accept)
    ]
    literal = Onibi::IRGen::YARVIR::SemanticBytecode::Literal.new("ᾀ", "ἀι")
    suffix = Onibi::IRGen::YARVIR::SemanticBytecode::Literal.new("a")
    alternate = Onibi::IRGen::YARVIR::SemanticBytecode::Literal.new("b")
    flat = Onibi::IRGen::YARVIR::SemanticBytecode::FlatProgram.new(
      instructions: instructions, operands: [literal, suffix, alternate]
    )

    metadata = flat.boundary_metadata(0)
    assert_equal suffix, metadata.next_literal
    assert_equal [suffix, alternate], metadata.next_literals
  end

  def test_flat_program_records_repeat_backedge
    instructions = [
      Onibi::IRGen::YARVIR::SemanticBytecode::VMInstruction.new(opcode: :fold_boundary, operand: 0, target: 1),
      Onibi::IRGen::YARVIR::SemanticBytecode::VMInstruction.new(opcode: :jump, target: 0)
    ]
    literal = Onibi::IRGen::YARVIR::SemanticBytecode::Literal.new("ᾀ", "ἀι")
    flat = Onibi::IRGen::YARVIR::SemanticBytecode::FlatProgram.new(
      instructions: instructions, operands: [literal]
    )

    metadata = flat.boundary_metadata(0)
    assert_equal [0], metadata.backedge_pcs
    assert metadata.repeat_backedge?
    assert_equal [0], flat.backedge_targets(0)
    assert_empty flat.backedge_targets(1)
  end

  def test_flat_assertion_operands_keep_only_leaf_atoms
    flat = Onibi::Regexp.new("(?=a[0-9])a7").send(:bytecode_program).instructions
                        .find { |instruction| instruction.opcode == :semantic_flat }.operand
    assertions = flat.operands.grep(Onibi::IRGen::YARVIR::SemanticBytecode::Assertion)

    refute_empty assertions
    assert assertions.all? do |assertion|
      Array(assertion.flat_atoms).flatten.all? do |atom|
        !atom.respond_to?(:body) && !atom.respond_to?(:parts) && !atom.respond_to?(:branches)
      end
    end
  end

  def test_flat_program_rejects_assertion_with_composite_atoms
    assertion = Onibi::IRGen::YARVIR::SemanticBytecode::Assertion.new(
      nil, :positive, [1], [1], [Onibi::IRGen::YARVIR::SemanticBytecode::Sequence.new([])]
    )

    assert_raises(ArgumentError) do
      Onibi::IRGen::YARVIR::SemanticBytecode::FlatProgram.new(
        instructions: [Onibi::IRGen::YARVIR::SemanticBytecode::VMInstruction.new(opcode: :accept)],
        operands: [assertion]
      )
    end
  end

  def test_flat_executor_does_not_retain_semantic_tree_entry
    program = Onibi::Regexp.new("(a|b)").send(:bytecode_program)
    executor = Onibi::Interpreter::Executor.new(program)

    refute executor.instance_variable_defined?(:@semantic_entry)
  end

  def test_retained_semantic_tree_selects_compatibility_executor
    root = Onibi::IRGen::YARVIR::SemanticBytecode.compile(Onibi::Parser.parse("a").ast)
    semantic_program = Onibi::IRGen::YARVIR::SemanticBytecode.lower(root)
    program = Onibi::IRGen::YARVIR::Program.new(
      instructions: [
        Onibi::IRGen::YARVIR::Instruction.new(opcode: :semantic_match, operand: semantic_program),
        Onibi::IRGen::YARVIR::Instruction.new(opcode: :semantic_flat, operand: semantic_program.flat_program)
      ]
    )

    assert_instance_of Onibi::Interpreter::CompatibilityExecutor,
                       Onibi::Interpreter::Executor.new(program)
  end

  def test_flat_call_return_uses_execution_state_frames
    regexp = Onibi::Regexp.new("(?<x>a)\\g<x>")
    executor = Onibi::Interpreter::Executor.new(regexp.send(:bytecode_program))

    assert_equal [0, 2], executor.match("aa")
    assert_empty executor.instance_variable_get(:@state).calls
    refute_includes executor.match_with_captures("aa")[2].keys, :__flat_call_stack
  end

  def test_flat_repeat_uses_and_releases_execution_state_frame
    regexp = Onibi::Regexp.new("a+")
    executor = Onibi::Interpreter::Executor.new(regexp.send(:bytecode_program))

    assert_equal [0, 3], executor.match("aaa")
    assert_empty executor.instance_variable_get(:@state).repeats
  end

  def test_flat_ordered_choice_records_and_releases_backtrack_points
    regexp = Onibi::Regexp.new("a|b")
    executor = Onibi::Interpreter::Executor.new(regexp.send(:bytecode_program))

    assert_equal [0, 1], executor.match("b")
    assert_empty executor.instance_variable_get(:@state).backtracks
  end

  def test_flat_choice_restores_capture_state_before_alternative
    regexp = Onibi::Regexp.new("(?:(?<x>a)c|(?<y>b)d)")
    executor = Onibi::Interpreter::Executor.new(regexp.send(:bytecode_program))

    result = executor.match_with_captures("bd")
    captures = result[2]
    assert_equal [0, 2], result.first(2)
    assert_nil captures[1]
    assert_equal [0, 1], captures[2]
    assert_empty executor.instance_variable_get(:@state).capture_frames
  end

  def test_flat_compiler_accepts_single_character_simple_casefold
    regexp = Onibi::Regexp.new("k", Onibi::Regexp::IGNORECASE)
    program = regexp.send(:bytecode_program)

    assert(program.instructions.any? { |item| item.opcode == :semantic_flat })
    assert_equal [0, 1], program.execute("K", 0)
  end

  def test_flat_compiler_accepts_ascii_literal_sequence_simple_casefold
    regexp = Onibi::Regexp.new("ab", Onibi::Regexp::IGNORECASE)
    program = regexp.send(:bytecode_program)

    assert(program.instructions.any? { |item| item.opcode == :semantic_flat })
    assert_equal [0, 2], program.execute("AB", 0)
  end

  def test_flat_compiler_accepts_single_character_unicode_simple_casefold
    regexp = Onibi::Regexp.new("é", Onibi::Regexp::IGNORECASE)
    program = regexp.send(:bytecode_program)

    assert(program.instructions.any? { |item| item.opcode == :semantic_flat })
    assert_equal [0, 1], program.execute("É", 0)
  end

  def test_flat_compiler_accepts_single_character_unicode_full_fold
    regexp = Onibi::Regexp.new("ß", Onibi::Regexp::IGNORECASE)
    program = regexp.send(:bytecode_program)

    assert(program.instructions.any? { |item| item.opcode == :semantic_flat })
    assert_equal [0, 2], program.execute("SS", 0)
  end

  def test_flat_compiler_accepts_non_capturing_full_fold_wrapper
    regexp = Onibi::Regexp.new("(?:ß)", Onibi::Regexp::IGNORECASE)
    program = regexp.send(:bytecode_program)

    assert(program.instructions.any? { |item| item.opcode == :semantic_flat })
    assert_equal [0, 2], program.execute("SS", 0)
  end

  def test_flat_operands_do_not_retain_composite_bodies
    regexp = Onibi::Regexp.new("(?=ab)(?<x>a)b")
    flat = regexp.send(:bytecode_program).instructions.find { |item| item.opcode == :semantic_flat }.operand
    assertion = flat.operands.find { |operand| operand.is_a?(Onibi::IRGen::YARVIR::SemanticBytecode::Assertion) }

    assert assertion
    assert_nil assertion.body
    assert assertion.flat_atoms
  end

  def test_flat_absence_operand_contains_atoms_without_tree_body
    regexp = Onibi::Regexp.new("(?~a)b")
    flat = regexp.send(:bytecode_program).instructions.find { |item| item.opcode == :semantic_flat }.operand
    absence = flat.operands.find { |operand| operand.is_a?(Onibi::IRGen::YARVIR::SemanticBytecode::Absence) }

    assert absence
    assert_nil absence.body
    assert absence.flat_atoms
  end

  def test_flat_quantifier_operand_does_not_retain_group_body
    regexp = Onibi::Regexp.new("(a)+b")
    flat = regexp.send(:bytecode_program).instructions.find { |item| item.opcode == :semantic_flat }.operand
    quantifier = flat.operands.find { |operand| operand.is_a?(Onibi::IRGen::YARVIR::SemanticBytecode::Quantifier) }

    assert quantifier
    refute quantifier.expression.is_a?(Onibi::IRGen::YARVIR::SemanticBytecode::Group)
  end

  def test_compiler_program_contains_tagged_vm_transitions
    program = Onibi::Regexp.new("(a)").send(:bytecode_program)

    assert_instance_of Onibi::Automata::TaggedDFA, program.tagged_automaton
    assert_includes program.instructions.map(&:opcode), :tagged_match
    assert_equal [0, 1], program.execute_with_captures("a")[2][1]
  end

  def test_flat_semantic_vm_executes_sequence_and_ordered_choice
    regexp = Onibi::Regexp.new("(a|b)c")
    program = regexp.send(:bytecode_program)
    flat = program.instructions.find { |item| item.opcode == :semantic_flat }

    assert_instance_of Onibi::IRGen::YARVIR::SemanticBytecode::FlatProgram, flat.operand
    assert_equal [2, 4], program.execute("xxac", 0)
    assert_equal [2, 4], program.execute("xxbc", 0)
    assert_nil program.execute("xxcc", 0)
  end

  def test_flat_semantic_vm_executes_ascii_quantifier_command
    regexp = Onibi::Regexp.new("a*b")
    program = regexp.send(:bytecode_program)

    assert(program.instructions.any? { |item| item.opcode == :semantic_flat })
    assert_equal [2, 5], program.execute("xxaab", 0)
  end

  def test_flat_semantic_vm_lowers_empty_alternation_branch_to_nop
    regexp = Onibi::Regexp.new("(a|)")
    program = regexp.send(:bytecode_program)
    flat = program.instructions.find { |item| item.opcode == :semantic_flat }.operand

    assert_includes flat.instructions.map(&:opcode), :nop
    assert_equal [0, 0], program.execute("x", 0)
    assert_equal [0, 1], program.execute("a", 0)
  end

  def test_flat_semantic_vm_lowers_variable_capture_group_loop
    regexp = Onibi::Regexp.new("(a)+b")
    program = regexp.send(:bytecode_program)

    assert(program.instructions.any? { |item| item.opcode == :semantic_flat })
    assert_equal [0, 4], program.execute("aaab", 0)
    assert_equal [0, 1], program.execute_with_captures("ab", 0)[2][1]
  end

  def test_flat_semantic_vm_lowers_bounded_capture_group_choices
    regexp = Onibi::Regexp.new("(a){1,3}b")
    program = regexp.send(:bytecode_program)

    assert(program.instructions.any? { |item| item.opcode == :semantic_flat })
    assert_equal [0, 4], program.execute("aaab", 0)
    assert_equal [0, 2], program.execute("ab", 0)
  end

  def test_flat_semantic_vm_executes_possessive_capture_group
    regexp = Onibi::Regexp.new("(a)++b")
    program = regexp.send(:bytecode_program)

    assert(program.instructions.any? { |item| item.opcode == :semantic_flat })
    assert_equal [0, 4], program.execute("aaab", 0)
    assert_nil program.execute("aaac", 0)
    assert_nil Onibi::Regexp.new("(a)++a").send(:bytecode_program).execute("aa", 0)
  end

  def test_flat_semantic_vm_lowers_fixed_quantified_capture_group
    regexp = Onibi::Regexp.new("(a){2}b")
    program = regexp.send(:bytecode_program)

    assert(program.instructions.any? { |item| item.opcode == :semantic_flat })
    assert_equal [0, 3], program.execute("aab", 0)
    assert_equal [1, 2], program.execute_with_captures("aab", 0)[2][1]
  end

  def test_flat_semantic_vm_executes_ascii_character_class
    regexp = Onibi::Regexp.new("[a-z]+!")
    program = regexp.send(:bytecode_program)

    assert(program.instructions.any? { |item| item.opcode == :semantic_flat })
    assert_equal [0, 4], program.execute("abc!", 0)
    assert_nil program.execute("ABC!", 0)
  end

  def test_flat_semantic_vm_executes_anchors
    regexp = Onibi::Regexp.new("^a$")
    program = regexp.send(:bytecode_program)

    assert(program.instructions.any? { |item| item.opcode == :semantic_flat })
    assert_equal [0, 1], program.execute("a", 0)
    assert_nil program.execute("ba", 0)
  end

  def test_flat_semantic_vm_executes_basic_escape
    regexp = Onibi::Regexp.new("\\d+")
    program = regexp.send(:bytecode_program)

    assert(program.instructions.any? { |item| item.opcode == :semantic_flat })
    assert_equal [0, 3], program.execute("123", 0)
    assert_nil program.execute("abc", 0)
  end

  def test_flat_semantic_vm_executes_word_boundary_escape
    regexp = Onibi::Regexp.new("\\bword\\b")
    program = regexp.send(:bytecode_program)

    assert(program.instructions.any? { |item| item.opcode == :semantic_flat })
    assert_equal [0, 4], program.execute("word", 0)
    assert_nil program.execute("sword", 0)
  end

  def test_flat_compiler_rejects_zero_width_capture_group_repeat
    regexp = Onibi::Regexp.new("(\\b)+")
    program = regexp.send(:bytecode_program)

    assert(program.instructions.any? { |item| item.opcode == :semantic_flat })
    assert_equal [0, 0], program.execute("word", 0)
  end

  def test_flat_semantic_vm_executes_linebreak_escape
    regexp = Onibi::Regexp.new("a\\Rb")
    program = regexp.send(:bytecode_program)

    assert(program.instructions.any? { |item| item.opcode == :semantic_flat })
    assert_equal [0, 3], program.execute("a\nb", 0)
  end

  def test_flat_semantic_vm_executes_start_match_escape
    regexp = Onibi::Regexp.new("\\Gabc")
    program = regexp.send(:bytecode_program)

    assert(program.instructions.any? { |item| item.opcode == :semantic_flat })
    assert_equal [0, 3], program.execute("abc", 0)
  end

  def test_flat_semantic_vm_executes_match_reset_escape
    regexp = Onibi::Regexp.new("a\\Kb")
    program = regexp.send(:bytecode_program)

    assert(program.instructions.any? { |item| item.opcode == :semantic_flat })
    assert_equal [1, 2], program.execute("ab", 0)
  end

  def test_flat_semantic_vm_executes_grapheme_escape
    regexp = Onibi::Regexp.new("\\X")
    program = regexp.send(:bytecode_program)

    assert(program.instructions.any? { |item| item.opcode == :semantic_flat })
    assert_equal [0, 2], program.execute("a\u0301", 0)
  end

  def test_flat_semantic_vm_executes_ascii_property
    regexp = Onibi::Regexp.new("\\p{ASCII}+")
    program = regexp.send(:bytecode_program)

    assert(program.instructions.any? { |item| item.opcode == :semantic_flat })
    assert_equal [0, 3], program.execute("Ab1", 0)
    assert_nil program.execute("é", 0)
  end

  def test_flat_semantic_vm_executes_utf8_unicode_property
    regexp = Onibi::Regexp.new("(\\p{L}+)")
    program = regexp.send(:bytecode_program)

    assert(program.instructions.any? { |item| item.opcode == :semantic_flat })
    assert_equal [0, 2], program.execute("あA1", 0)
  end

  def test_flat_semantic_vm_executes_exact_utf8_literal
    regexp = Onibi::Regexp.new("(あ+)")
    program = regexp.send(:bytecode_program)

    assert(program.instructions.any? { |item| item.opcode == :semantic_flat })
    assert_equal [0, 2], program.execute("ああ!", 0)
  end

  def test_flat_semantic_vm_executes_scoped_unicode_unbounded_repeat
    source = "(?i:é+)"
    regexp = Onibi::Regexp.new(source)
    program = regexp.send(:bytecode_program)

    refute(program.instructions.any? { |item| item.opcode == :semantic_match })
    assert(program.instructions.any? { |item| item.opcode == :semantic_flat })
    ["é", "É", "éÉ", "Éé", "x"].each do |input|
      expected = ::Regexp.new(source).match(input)
      actual = regexp.match(input)
      assert_equal expected&.to_a, actual&.to_a, input
    end
  end

  def test_flat_semantic_vm_executes_scoped_unicode_bounded_repeats
    ["(?i:é?)", "(?i:é{2})", "(?i:é{0,3})", "(?i:é{2,4})"].each do |source|
      regexp = Onibi::Regexp.new(source)
      program = regexp.send(:bytecode_program)

      refute program.instructions.any? { |item| item.opcode == :semantic_match }, source
      assert program.instructions.any? { |item| item.opcode == :semantic_flat }, source
      ["", "é", "É", "éÉ", "Ééé", "éééé", "x"].each do |input|
        expected = ::Regexp.new(source).match(input)
        actual = regexp.match(input)
        assert_equal expected&.to_a, actual&.to_a, [source, input]
      end
    end
  end

  def test_flat_semantic_vm_executes_scoped_unicode_unbounded_repeat_suffix
    source = "(?i:é+)a"
    regexp = Onibi::Regexp.new(source)
    program = regexp.send(:bytecode_program)

    refute program.instructions.any? { |item| item.opcode == :semantic_match }, source
    assert program.instructions.any? { |item| item.opcode == :semantic_flat }, source
    ["éa", "Éa", "éÉa", "ééa", "é", "xéa", "ÉÉA"].each do |input|
      expected = ::Regexp.new(source).match(input)
      actual = regexp.match(input)
      assert_equal expected&.to_a, actual&.to_a, [source, input]
    end
  end

  def test_flat_semantic_vm_executes_scoped_unicode_repeat_alternation
    source = "(?i:é+|a)"
    regexp = Onibi::Regexp.new(source)
    program = regexp.send(:bytecode_program)

    refute program.instructions.any? { |item| item.opcode == :semantic_match }, source
    assert program.instructions.any? { |item| item.opcode == :semantic_flat }, source
    ["é", "É", "éé", "Éé", "a", "A", "éa", "xé", "xA", ""].each do |input|
      expected = ::Regexp.new(source).match(input)
      actual = regexp.match(input)
      assert_equal expected&.to_a, actual&.to_a, [source, input]
    end
  end

  def test_flat_semantic_vm_executes_scoped_unicode_repeat_alternation_suffix
    source = "(?i:é+|a)b"
    regexp = Onibi::Regexp.new(source)
    program = regexp.send(:bytecode_program)

    refute program.instructions.any? { |item| item.opcode == :semantic_match }, source
    assert program.instructions.any? { |item| item.opcode == :semantic_flat }, source
    ["éb", "Éb", "éÉb", "ab", "Ab", "é", "xéb", "éba"].each do |input|
      expected = ::Regexp.new(source).match(input)
      actual = regexp.match(input)
      assert_equal expected&.to_a, actual&.to_a, [source, input]
    end
  end

  def test_flat_semantic_vm_executes_scoped_unicode_capture_repeats
    ["(?i:(é)+)", "(?i:(?<x>é)+)"].each do |source|
      regexp = Onibi::Regexp.new(source)
      program = regexp.send(:bytecode_program)

      refute program.instructions.any? { |item| item.opcode == :semantic_match }, source
      assert program.instructions.any? { |item| item.opcode == :semantic_flat }, source
      ["é", "É", "éÉ", "Éé", "xé"].each do |input|
        expected = ::Regexp.new(source).match(input)
        actual = regexp.match(input)
        assert_equal expected&.to_a, actual&.to_a, [source, input]
      end
    end
  end

  def test_flat_semantic_vm_executes_scoped_unicode_repeat_before_capture
    source = "(?i:é+)(a)"
    regexp = Onibi::Regexp.new(source)
    program = regexp.send(:bytecode_program)

    refute program.instructions.any? { |item| item.opcode == :semantic_match }, source
    assert program.instructions.any? { |item| item.opcode == :semantic_flat }, source
    ["éa", "Éa", "éÉa", "ééa", "é", "xéa", "éaa"].each do |input|
      expected = ::Regexp.new(source).match(input)
      actual = regexp.match(input)
      assert_equal expected&.to_a, actual&.to_a, [source, input]
    end
  end

  def test_flat_semantic_vm_executes_scoped_unicode_capture_repeat_suffix
    source = "(?i:(é|a)+b)"
    regexp = Onibi::Regexp.new(source)
    program = regexp.send(:bytecode_program)

    refute program.instructions.any? { |item| item.opcode == :semantic_match }, source
    assert program.instructions.any? { |item| item.opcode == :semantic_flat }, source
    ["éb", "Éb", "ab", "aéb", "éab", "é", "xéb"].each do |input|
      expected = ::Regexp.new(source).match(input)
      actual = regexp.match(input)
      assert_equal expected&.to_a, actual&.to_a, [source, input]
    end
  end

  def test_flat_semantic_vm_executes_scoped_unicode_bounded_capture_repeat_suffix
    source = "(?i:(é|a){2,4}b)"
    regexp = Onibi::Regexp.new(source)
    program = regexp.send(:bytecode_program)

    refute program.instructions.any? { |item| item.opcode == :semantic_match }, source
    assert program.instructions.any? { |item| item.opcode == :semantic_flat }, source
    ["ééb", "Éab", "éééb", "ééééb", "éb", "éé", "xééb"].each do |input|
      expected = ::Regexp.new(source).match(input)
      actual = regexp.match(input)
      assert_equal expected&.to_a, actual&.to_a, [source, input]
    end
  end

  def test_flat_semantic_vm_executes_scoped_unicode_capture_backreference
    source = "(?i:(?<x>é)\\k<x>)"
    regexp = Onibi::Regexp.new(source)
    program = regexp.send(:bytecode_program)

    refute program.instructions.any? { |item| item.opcode == :semantic_match }, source
    assert program.instructions.any? { |item| item.opcode == :semantic_flat }, source
    ["éé", "éÉ", "Éé", "ÉÉ", "ée", "xéé"].each do |input|
      expected = ::Regexp.new(source).match(input)
      actual = regexp.match(input)
      assert_equal expected&.to_a, actual&.to_a, [source, input]
    end
  end

  def test_flat_semantic_vm_executes_scoped_unicode_bounded_capture_backreference
    source = "(?i:(?<x>é){2}\\k<x>)"
    regexp = Onibi::Regexp.new(source)
    program = regexp.send(:bytecode_program)

    refute program.instructions.any? { |item| item.opcode == :semantic_match }, source
    assert program.instructions.any? { |item| item.opcode == :semantic_flat }, source
    ["éééé", "ééÉé", "Éééé", "ÉÉéé", "éé", "xéééé"].each do |input|
      expected = ::Regexp.new(source).match(input)
      actual = regexp.match(input)
      assert_equal expected&.to_a, actual&.to_a, [source, input]
    end
  end

  def test_flat_semantic_vm_executes_scoped_unicode_unbounded_capture_backreference
    source = "(?i:(?<x>é)+\\k<x>)"
    regexp = Onibi::Regexp.new(source)
    program = regexp.send(:bytecode_program)

    refute program.instructions.any? { |item| item.opcode == :semantic_match }, source
    assert program.instructions.any? { |item| item.opcode == :semantic_flat }, source
    ["éé", "ééé", "éÉ", "éÉé", "Ééé", "ÉÉé", "xéé"].each do |input|
      expected = ::Regexp.new(source).match(input)
      actual = regexp.match(input)
      assert_equal expected&.to_a, actual&.to_a, [source, input]
    end
  end

  def test_flat_semantic_vm_executes_scoped_unicode_backreference_suffix
    source = "(?i:(?<x>é+)\\k<x>)b"
    regexp = Onibi::Regexp.new(source)
    program = regexp.send(:bytecode_program)

    refute program.instructions.any? { |item| item.opcode == :semantic_match }, source
    assert program.instructions.any? { |item| item.opcode == :semantic_flat }, source
    ["ééb", "éééb", "éÉb", "Éééb", "éé", "xééb"].each do |input|
      expected = ::Regexp.new(source).match(input)
      actual = regexp.match(input)
      assert_equal expected&.to_a, actual&.to_a, [source, input]
    end
  end

  def test_flat_semantic_vm_executes_scoped_unicode_bounded_backreference_suffix
    source = "(?i:(?<x>é){2}\\k<x>)b"
    regexp = Onibi::Regexp.new(source)
    program = regexp.send(:bytecode_program)

    refute program.instructions.any? { |item| item.opcode == :semantic_match }, source
    assert program.instructions.any? { |item| item.opcode == :semantic_flat }, source
    ["ééééb", "ééÉéb", "Ééééb", "éééé", "xéééb"].each do |input|
      expected = ::Regexp.new(source).match(input)
      actual = regexp.match(input)
      assert_equal expected&.to_a, actual&.to_a, [source, input]
    end
  end

  def test_flat_semantic_vm_executes_scoped_unicode_capture_conditional
    source = "(?i:(?<x>é)(?(<x>)a|b))"
    regexp = Onibi::Regexp.new(source)
    program = regexp.send(:bytecode_program)

    refute program.instructions.any? { |item| item.opcode == :semantic_match }, source
    assert program.instructions.any? { |item| item.opcode == :semantic_flat }, source
    ["éa", "Éa", "éb", "xéa", "é"].each do |input|
      expected = ::Regexp.new(source).match(input)
      actual = regexp.match(input)
      assert_equal expected&.to_a, actual&.to_a, [source, input]
    end
  end

  def test_flat_semantic_vm_executes_exact_utf8_character_class
    regexp = Onibi::Regexp.new("([あ-お]+)")
    program = regexp.send(:bytecode_program)

    assert(program.instructions.any? { |item| item.opcode == :semantic_flat })
    assert_equal [0, 2], program.execute("いう!", 0)
  end

  def test_flat_semantic_vm_executes_negated_character_class
    regexp = Onibi::Regexp.new("([^a]+)")
    program = regexp.send(:bytecode_program)

    assert(program.instructions.any? { |item| item.opcode == :semantic_flat })
    assert_equal [0, 3], program.execute("bc!", 0)
  end

  def test_flat_semantic_vm_executes_sequence_assertion_atoms
    regexp = Onibi::Regexp.new("(?=a[0-9])a[0-9]")
    program = regexp.send(:bytecode_program)

    assert(program.instructions.any? { |item| item.opcode == :semantic_flat })
    assert_equal [0, 2], program.execute("a7", 0)
    assert_nil program.execute("ab", 0)
  end

  def test_flat_semantic_vm_executes_non_literal_absence_body
    regexp = Onibi::Regexp.new("((?~[a-z]))")
    program = regexp.send(:bytecode_program)

    assert(program.instructions.any? { |item| item.opcode == :semantic_flat })
    assert_equal [0, 2], program.execute("12a", 0)
  end

  def test_flat_semantic_vm_executes_backreference_assertion_atom
    regexp = Onibi::Regexp.new("(a)(?=\\1)\\1")
    program = regexp.send(:bytecode_program)

    assert(program.instructions.any? { |item| item.opcode == :semantic_flat })
    assert_equal [0, 2], program.execute("aa", 0)
    assert_nil program.execute("ab", 0)
  end

  def test_flat_semantic_vm_executes_backreference_quantifier
    regexp = Onibi::Regexp.new("(a)\\1+")
    program = regexp.send(:bytecode_program)

    assert(program.instructions.any? { |item| item.opcode == :semantic_flat })
    assert_equal [0, 3], program.execute("aaa", 0)
    assert_equal [0, 2], program.execute("aa", 0)
  end

  def test_flat_semantic_vm_executes_zero_width_assertion_atom
    regexp = Onibi::Regexp.new("(?=\\b)a")
    program = regexp.send(:bytecode_program)

    assert(program.instructions.any? { |item| item.opcode == :semantic_flat })
    assert_equal [0, 1], program.execute("a", 0)
    assert_equal [1, 2], program.execute(" a", 0)
  end

  def test_flat_semantic_vm_executes_zero_width_assertion_repeat
    regexp = Onibi::Regexp.new("(?=a)+")
    program = regexp.send(:bytecode_program)

    assert(program.instructions.any? { |item| item.opcode == :semantic_flat })
    assert_equal [0, 0], program.execute("a", 0)
  end

  def test_flat_semantic_vm_executes_zero_width_escape_repeat
    regexp = Onibi::Regexp.new("\\b+")
    program = regexp.send(:bytecode_program)

    assert(program.instructions.any? { |item| item.opcode == :semantic_flat })
    assert_equal [0, 0], program.execute("word", 0)
  end

  def test_flat_semantic_vm_executes_fixed_zero_width_assertion_repeat
    regexp = Onibi::Regexp.new("(?=a){2}")
    program = regexp.send(:bytecode_program)

    assert(program.instructions.any? { |item| item.opcode == :semantic_flat })
    assert_equal [0, 0], program.execute("a", 0)
    assert_nil program.execute("b", 0)
  end

  def test_flat_semantic_vm_preserves_fixed_zero_width_capture
    regexp = Onibi::Regexp.new("(\\b){2}")
    program = regexp.send(:bytecode_program)

    assert(program.instructions.any? { |item| item.opcode == :semantic_flat })
    result = program.execute_with_captures("word", 0)
    assert_equal [0, 0], result.first(2)
    assert_equal [0, 0], result[2][1]
  end

  def test_flat_semantic_vm_executes_grapheme_assertion_atom
    regexp = Onibi::Regexp.new("(?=\\X)\\X")
    program = regexp.send(:bytecode_program)

    assert(program.instructions.any? { |item| item.opcode == :semantic_flat })
    assert_equal [0, 2], program.execute("a\u0301", 0)
  end

  def test_flat_semantic_vm_executes_lazy_exact_quantifier
    regexp = Onibi::Regexp.new("(a{2}?)b")
    program = regexp.send(:bytecode_program)

    assert(program.instructions.any? { |item| item.opcode == :semantic_flat })
    assert_equal [1, 2], program.execute("ab", 0)
    assert_equal [2, 3], program.execute("aab", 0)
  end

  def test_flat_semantic_vm_commits_atomic_choice
    regexp = Onibi::Regexp.new("(?>a|ab)c")
    program = regexp.send(:bytecode_program)
    flat = program.instructions.find { |item| item.opcode == :semantic_flat }.operand

    assert_includes flat.instructions.map(&:opcode), :atomic_start
    assert_includes flat.instructions.map(&:opcode), :atomic_end
    assert_equal [0, 2], program.execute("ac", 0)
    assert_nil program.execute("abc", 0)
  end

  def test_flat_semantic_vm_executes_possessive_sequence_group
    regexp = Onibi::Regexp.new("([a-z][0-9])++b")
    program = regexp.send(:bytecode_program)

    assert(program.instructions.any? { |item| item.opcode == :semantic_flat })
    assert_equal [0, 5], program.execute("a1b2b", 0)
    assert_nil program.execute("a1b2", 0)
  end

  def test_flat_compiler_handles_programs_larger_than_legacy_limit
    source = "#{"a" * 30}(b)"
    regexp = Onibi::Regexp.new(source)
    program = regexp.send(:bytecode_program)

    assert(program.instructions.any? { |item| item.opcode == :semantic_flat })
    assert_equal [0, 31], program.execute("#{"a" * 30}b", 0)
  end

  def test_flat_semantic_vm_executes_numeric_backreference
    regexp = Onibi::Regexp.new("(a)\\1")
    program = regexp.send(:bytecode_program)

    assert(program.instructions.any? { |item| item.opcode == :semantic_flat })
    assert_equal [2, 4], program.execute("xxaa", 0)
    assert_nil program.execute("xxab", 0)
  end

  def test_flat_semantic_vm_executes_named_backreference
    regexp = Onibi::Regexp.new("(?<x>a)\\k<x>")
    program = regexp.send(:bytecode_program)

    assert(program.instructions.any? { |item| item.opcode == :semantic_flat })
    assert_equal [0, 2], program.execute("aa", 0)
    assert_nil program.execute("ab", 0)
  end

  def test_flat_semantic_vm_executes_named_conditional
    regexp = Onibi::Regexp.new("(?<x>a)(?(<x>)b|c)")
    program = regexp.send(:bytecode_program)

    assert(program.instructions.any? { |item| item.opcode == :semantic_flat })
    assert_equal [0, 2], program.execute("ab", 0)
    assert_nil program.execute("ac", 0)
  end

  def test_flat_semantic_vm_executes_lookahead_assertion
    positive = Onibi::Regexp.new("a(?=b)b").send(:bytecode_program)
    negative = Onibi::Regexp.new("a(?!c)b").send(:bytecode_program)

    assert_equal [2, 4], positive.execute("xxab", 0)
    assert_equal [2, 4], negative.execute("xxab", 0)
    assert_nil negative.execute("xxac", 0)
  end

  def test_flat_semantic_vm_preserves_capture_from_lookahead
    regexp = Onibi::Regexp.new("(?=(a))a\\1")
    program = regexp.send(:bytecode_program)

    assert(program.instructions.any? { |item| item.opcode == :semantic_flat })
    result = program.execute_with_captures("aa", 0)
    assert_equal [0, 2], result.first(2)
    assert_equal [0, 1], result[2][1]
  end

  def test_flat_semantic_vm_preserves_capture_from_alternating_lookahead
    regexp = Onibi::Regexp.new("(?=(a|b))\\1")
    program = regexp.send(:bytecode_program)

    assert(program.instructions.any? { |item| item.opcode == :semantic_flat })
    assert_equal [0, 1], program.execute("a", 0)
    assert_equal [0, 1], program.execute("b", 0)
    assert_equal [0, 1], program.execute("ab", 0)
  end

  def test_flat_semantic_vm_preserves_quantifier_order_in_capture_lookahead
    greedy = Onibi::Regexp.new("(?=(a{1,2}))\\1").send(:bytecode_program)
    lazy = Onibi::Regexp.new("(?=(a{1,2}?))\\1").send(:bytecode_program)

    [greedy, lazy].each do |program|
      assert(program.instructions.any? { |item| item.opcode == :semantic_flat })
    end
    assert_equal [0, 2], greedy.execute("aaa", 0)
    assert_equal [0, 1], lazy.execute("aaa", 0)
  end

  def test_flat_semantic_vm_handles_possessive_quantifier_in_capture_lookahead
    regexp = Onibi::Regexp.new("(?=(a{1,2}+))\\1")
    program = regexp.send(:bytecode_program)

    assert(program.instructions.any? { |item| item.opcode == :semantic_flat })
    assert_equal [0, 2], program.execute("aa", 0)
    assert_equal [0, 3], program.execute("aaa", 0)

    no_backtrack = Onibi::Regexp.new("(?=(a{1,2}+))\\1a").send(:bytecode_program)
    assert_nil no_backtrack.execute("aa", 0)
  end

  def test_flat_semantic_vm_handles_zero_width_quantifier_in_capture_lookahead
    regexp = Onibi::Regexp.new("(?=(\\b*))\\1")
    program = regexp.send(:bytecode_program)

    assert(program.instructions.any? { |item| item.opcode == :semantic_flat })
    result = program.execute_with_captures("a", 0)
    assert_equal [0, 0], result.first(2)
    assert_equal [0, 0], result[2][1]
  end

  def test_flat_semantic_vm_handles_nested_zero_width_assertion_capture
    regexp = Onibi::Regexp.new("(?=(\\b(?=a)))\\1")
    program = regexp.send(:bytecode_program)

    assert(program.instructions.any? { |item| item.opcode == :semantic_flat })
    result = program.execute_with_captures("a", 0)
    assert_equal [0, 0], result.first(2)
    assert_equal [0, 0], result[2][1]
  end

  def test_flat_semantic_vm_handles_nested_zero_width_lookbehind_capture
    positive = Onibi::Regexp.new("(?<=(a(?=b)))b").send(:bytecode_program)
    negative = Onibi::Regexp.new("(?<!(a(?=b)))b").send(:bytecode_program)

    [positive, negative].each do |program|
      assert(program.instructions.any? { |item| item.opcode == :semantic_flat })
    end
    positive_result = positive.execute_with_captures("ab", 0)
    assert_equal [1, 2], positive_result.first(2)
    assert_equal [0, 1], positive_result[2][1]
    assert_equal [1, 2], negative.execute("cb", 0)
    assert_nil negative.execute("ab", 0)
  end

  def test_flat_semantic_vm_resolves_backreference_inside_capture_lookahead
    positive = Onibi::Regexp.new("(?=(a)\\1)\\1").send(:bytecode_program)
    named = Onibi::Regexp.new("(?=(?<x>a)\\k<x>)\\k<x>").send(:bytecode_program)

    [positive, named].each do |program|
      assert(program.instructions.any? { |item| item.opcode == :semantic_flat })
    end
    assert_equal [0, 1], positive.execute("aa", 0)
    assert_nil positive.execute("ab", 0)
    assert_equal [0, 1], named.execute("aa", 0)
    assert_nil named.execute("ab", 0)
  end

  def test_flat_semantic_vm_resolves_fixed_backreference_inside_lookbehind
    numeric = Onibi::Regexp.new("(?<=(a)\\1)b").send(:bytecode_program)
    named = Onibi::Regexp.new("(?<=(?<x>a)\\k<x>)b").send(:bytecode_program)

    [numeric, named].each do |program|
      assert(program.instructions.any? { |item| item.opcode == :semantic_flat })
      assert_equal [2, 3], program.execute("aab", 0)
      assert_nil program.execute("abb", 0)
    end
  end

  def test_flat_semantic_vm_resolves_conditional_inside_capture_lookahead
    regexp = Onibi::Regexp.new("(?=(a)(?(1)b|c))\\1b")
    program = regexp.send(:bytecode_program)

    assert(program.instructions.any? { |item| item.opcode == :semantic_flat })
    result = program.execute_with_captures("ab", 0)
    assert_equal [0, 2], result.first(2)
    assert_equal [0, 1], result[2][1]
    assert_nil program.execute("ac", 0)
  end

  def test_flat_semantic_vm_resolves_backreference_after_fixed_alternation_lookbehind
    alternation = Onibi::Regexp.new("(?<=(a|b)\\1)c").send(:bytecode_program)
    quantified = Onibi::Regexp.new("(?<=(a{2})\\1)c").send(:bytecode_program)

    [alternation, quantified].each do |program|
      assert(program.instructions.any? { |item| item.opcode == :semantic_flat })
    end
    assert_equal [2, 3], alternation.execute("aac", 0)
    assert_equal [4, 5], quantified.execute("aaaac", 0)
    assert_nil alternation.execute("abc", 0)
    assert_nil quantified.execute("aaac", 0)
  end

  def test_flat_semantic_vm_resolves_exact_possessive_lookbehind_width
    possessive = Onibi::Regexp.new("(?<=(a{2}+)\\1)c").send(:bytecode_program)
    lazy = Onibi::Regexp.new("(?<=(a{2}?)\\1)c").send(:bytecode_program)

    [possessive, lazy].each do |program|
      assert(program.instructions.any? { |item| item.opcode == :semantic_flat })
      assert_equal [4, 5], program.execute("aaaac", 0)
      assert_nil program.execute("aaac", 0)
    end
  end

  def test_flat_semantic_vm_executes_literal_sequence_lookahead
    regexp = Onibi::Regexp.new("(?=abc)abc")
    program = regexp.send(:bytecode_program)

    assert(program.instructions.any? { |item| item.opcode == :semantic_flat })
    assert_equal [0, 3], program.execute("abc", 0)
  end

  def test_flat_semantic_vm_executes_literal_alternation_lookahead
    regexp = Onibi::Regexp.new("(?=a|b)[ab]")
    program = regexp.send(:bytecode_program)

    assert(program.instructions.any? { |item| item.opcode == :semantic_flat })
    assert_equal [0, 1], program.execute("b", 0)
    assert_nil program.execute("c", 0)
  end

  def test_flat_semantic_vm_executes_literal_lookbehind_assertion
    positive = Onibi::Regexp.new("(?<=a)b")
    negative = Onibi::Regexp.new("(?<!a)b")

    positive_program = positive.send(:bytecode_program)
    negative_program = negative.send(:bytecode_program)
    assert(positive_program.instructions.any? { |item| item.opcode == :semantic_flat })
    assert_equal [1, 2], positive_program.execute("ab", 0)
    assert_equal [1, 2], negative_program.execute("cb", 0)
  end

  def test_flat_semantic_vm_executes_literal_absence
    regexp = Onibi::Regexp.new("(?~a)b")
    program = regexp.send(:bytecode_program)

    assert(program.instructions.any? { |item| item.opcode == :semantic_flat })
    assert_equal [0, 2], program.execute("xb", 0)
    assert_equal [1, 2], program.execute("ab", 0)
  end

  def test_flat_semantic_vm_executes_alternating_literal_absence
    regexp = Onibi::Regexp.new("(?~a|b)")
    program = regexp.send(:bytecode_program)

    assert(program.instructions.any? { |item| item.opcode == :semantic_flat })
    assert_equal [0, 3], program.execute("xyz", 0)
    assert_equal [0, 1], program.execute("xab", 0)
  end

  def test_flat_semantic_vm_executes_fixed_quantifier_absence
    regexp = Onibi::Regexp.new("(?~a{2})")
    program = regexp.send(:bytecode_program)

    assert(program.instructions.any? { |item| item.opcode == :semantic_flat })
    assert_equal [0, 1], program.execute("b", 0)
    assert_equal [0, 1], program.execute("aa", 0)
  end

  def test_flat_semantic_vm_executes_bounded_quantifier_absence
    regexp = Onibi::Regexp.new("(?~a{1,2})")
    program = regexp.send(:bytecode_program)

    assert(program.instructions.any? { |item| item.opcode == :semantic_flat })
    assert_equal [0, 1], program.execute("b", 0)
    assert_equal [0, 1], program.execute("aa", 0)
  end

  def test_unbounded_absence_stays_on_compatibility_path
    program = Onibi::Regexp.new("(?~a+)").send(:bytecode_program)

    assert(program.instructions.any? { |item| item.opcode == :semantic_flat })
    refute(program.instructions.any? { |item| item.opcode == :semantic_vm })
    assert_equal [0, 1], program.execute("aa", 0)
  end

  def test_flat_semantic_vm_executes_unbounded_non_capturing_group_absence
    regexp = Onibi::Regexp.new("(?~(?:ab)+)")
    program = regexp.send(:bytecode_program)

    assert(program.instructions.any? { |item| item.opcode == :semantic_flat })
    assert_equal [0, 1], program.execute("ab", 0)
    assert_equal [0, 2], program.execute("aa", 0)
  end

  def test_flat_semantic_vm_executes_unbounded_class_absence
    regexp = Onibi::Regexp.new("(?~[ab]{2,})")
    program = regexp.send(:bytecode_program)

    assert(program.instructions.any? { |item| item.opcode == :semantic_flat })
    assert_equal [0, 2], program.execute("aaaa", 0)
    assert_equal [0, 2], program.execute("abab", 0)
  end

  def test_flat_semantic_vm_executes_unbounded_property_absence
    regexp = Onibi::Regexp.new("(?~\\p{ASCII}{2,})")
    program = regexp.send(:bytecode_program)

    assert(program.instructions.any? { |item| item.opcode == :semantic_flat })
    assert_equal [0, 2], program.execute("aaaa", 0)
    assert_equal [0, 1], program.execute("x", 0)
  end

  def test_flat_semantic_vm_executes_unbounded_escape_absence
    regexp = Onibi::Regexp.new("(?~\\d{2,})")
    program = regexp.send(:bytecode_program)

    assert(program.instructions.any? { |item| item.opcode == :semantic_flat })
    assert_equal [0, 2], program.execute("123a", 0)
    assert_equal [0, 2], program.execute("a12", 0)
    assert_equal [0, 1], program.execute("1", 0)
  end

  def test_flat_semantic_vm_executes_unbounded_any_absence
    regexp = Onibi::Regexp.new("(?~.{2,})")
    program = regexp.send(:bytecode_program)

    assert(program.instructions.any? { |item| item.opcode == :semantic_flat })
    assert_equal [0, 2], program.execute("abcd", 0)
    assert_equal [0, 1], program.execute("a", 0)
  end

  def test_flat_semantic_vm_executes_non_capturing_group_absence
    regexp = Onibi::Regexp.new("(?~(?:ab|cd))")
    program = regexp.send(:bytecode_program)

    assert(program.instructions.any? { |item| item.opcode == :semantic_flat })
    assert_equal [0, 1], program.execute("a", 0)
    assert_equal [0, 1], program.execute("abx", 0)
  end

  def test_flat_semantic_vm_lowers_safe_atomic_group
    regexp = Onibi::Regexp.new("(?>ab)c")
    program = regexp.send(:bytecode_program)

    assert(program.instructions.any? { |item| item.opcode == :semantic_flat })
    assert_equal [0, 3], program.execute("abc", 0)
  end

  def test_flat_compiler_lowers_option_group_without_flag_changes
    node = Onibi::AST::OptionGroup.new(Onibi::AST::Literal.new("a"), nil, nil, nil)
    root = Onibi::IRGen::YARVIR::SemanticBytecode.compile(node)
    semantic = Onibi::IRGen::YARVIR::SemanticBytecode.lower(root)

    assert semantic.flat_program
  end

  def test_flat_semantic_vm_scopes_ascii_ignorecase
    regexp = Onibi::Regexp.new("(?i:(a|b))")
    program = regexp.send(:bytecode_program)

    assert(program.instructions.any? { |item| item.opcode == :semantic_flat })
    assert_equal [0, 1], program.execute("A", 0)
    assert_equal [0, 1], program.execute("b", 0)
  end

  def test_flat_semantic_vm_scopes_inline_multiline
    regexp = Onibi::Regexp.new("(?m:^a$)")
    program = regexp.send(:bytecode_program)

    assert(program.instructions.any? { |item| item.opcode == :semantic_flat })
    assert_equal [2, 3], program.execute("x\na\ny", 0)
  end

  def test_flat_semantic_vm_scopes_inline_extended_mode
    regexp = Onibi::Regexp.new("(?x:a  b)")
    program = regexp.send(:bytecode_program)

    assert(program.instructions.any? { |item| item.opcode == :semantic_flat })
    assert_equal [0, 2], program.execute("ab", 0)
  end

  def test_flat_semantic_vm_inlines_named_subexpression_call
    regexp = Onibi::Regexp.new("(?<x>a)\\g<x>")
    program = regexp.send(:bytecode_program)

    assert(program.instructions.any? { |item| item.opcode == :semantic_flat })
    flat = program.instructions.find { |item| item.opcode == :semantic_flat }.operand
    assert_includes flat.instructions.map(&:opcode), :call
    assert_includes flat.instructions.map(&:opcode), :return
    assert_equal [0, 2], program.execute("aa", 0)
    assert_nil program.execute("ab", 0)
  end

  def test_flat_semantic_vm_executes_consuming_recursive_call
    regexp = Onibi::Regexp.new("(?<x>a\\g<x>|b)")
    program = regexp.send(:bytecode_program)

    assert(program.instructions.any? { |item| item.opcode == :semantic_flat })
    flat = program.instructions.find { |item| item.opcode == :semantic_flat }.operand
    assert_includes flat.instructions.map(&:opcode), :call
    assert_includes flat.instructions.map(&:opcode), :return
    assert_equal [0, 4], program.execute("aaab", 0)
    assert_equal [0, 1], program.execute("b", 0)
  end

  def test_common_vm_executes_tnfa_bytecode
    tnfa = tnfa_for(sequence("a", "b"))
    program = Onibi::IRGen::YARVIR.generate(tnfa, mode: :nfa)

    assert_equal [2, 4], Onibi::IRGen::YARVIR.execute(program, "xxabyy", 0)
    assert_nil Onibi::IRGen::YARVIR.execute(program, "xxacyy", 0)
  end

  def test_common_vm_tracks_tnfa_captures
    tnfa = tnfa_for(Onibi::AST::Group.new(sequence("a", "b"), 1, true, "pair"))
    program = Onibi::IRGen::YARVIR.generate(tnfa, mode: :nfa)

    assert_equal [2, 4, { 1 => [2, 4], "pair" => [2, 4] }],
                 Onibi::IRGen::YARVIR.execute_with_captures(program, "xxabyy", 0)
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

  def test_character_class_embeds_casefold_split_policy
    sharp_s = Onibi::Regexp.new("[ß]", Onibi::Regexp::IGNORECASE)
    ligature = Onibi::Regexp.new("[ﬆ]", Onibi::Regexp::IGNORECASE)

    sharp_s_root = Onibi::IRGen::YARVIR::SemanticBytecode.compile(sharp_s.ast, casefold: true)
    ligature_root = Onibi::IRGen::YARVIR::SemanticBytecode.compile(ligature.ast, casefold: true)

    assert sharp_s_root.parts.first.split_casefold
    refute ligature_root.parts.first.split_casefold
  end

  def test_character_class_embeds_fold_boundary_metadata
    regexp = Onibi::Regexp.new("[ᾀ]", Onibi::Regexp::IGNORECASE)
    operand = Onibi::IRGen::YARVIR::SemanticBytecode.compile(regexp.ast, casefold: true).parts.first

    assert_equal({ kind: :expanded_tail, tail: "ι", sensitive: true }, operand.fold_boundaries["ᾀ"])
  end

  def test_fold_policy_is_embedded_in_unicode_operands
    literal = Onibi::IRGen::YARVIR::SemanticBytecode.compile(
      Onibi::AST::Literal.new("ι"), casefold: true
    )
    character_class = Onibi::IRGen::YARVIR::SemanticBytecode.compile(
      Onibi::AST::CharacterClass.new("ι"), casefold: true
    )

    assert_equal :fold_group_variant, literal.fold_policy[:anchor_source]
    assert_equal :consume_source_variant, character_class.fold_policy[:optional_order]
  end

  def test_character_class_embeds_compiled_predicate_operands
    operand = Onibi::IRGen::YARVIR::SemanticBytecode.compile(
      Onibi::Parser.parse("[a-z]").ast
    ).parts.first

    assert operand.compiled_sensitive
    assert operand.compiled_insensitive
    assert operand.compiled_sensitive.matches?("m")
    refute operand.compiled_sensitive.matches?("0")
  end

  def test_character_class_fold_groups_are_only_compiled_for_casefolding
    plain = Onibi::IRGen::YARVIR::SemanticBytecode.compile(
      Onibi::AST::CharacterClass.new("[\\p{Upper}&&[^A-Z]]")
    )
    folded = Onibi::IRGen::YARVIR::SemanticBytecode.compile(
      Onibi::AST::CharacterClass.new("[\\p{Upper}&&[^A-Z]]"), casefold: true
    )

    assert_empty plain.folded_characters
    assert_includes folded.folded_characters, "K"
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

  def test_repeat_bytecode_records_fold_lazy_exact_bounds
    node = Onibi::AST::Quantifier.new(Onibi::AST::Literal.new("a"), :bounded, 2, 2, :lazy, true)
    operand = program_for(node).instructions[1].operand.last

    assert_equal [0, 2, true], [operand.minimum, operand.maximum, operand.lazy_exact]
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
    assert_equal [[:match_literal, Onibi::IRGen::YARVIR::SemanticBytecode::Literal.new("a", nil, nil, false)]],
                 program.instructions.select { |instruction| instruction.opcode == :match }.map(&:operand)
  end

  def test_dedicated_executor_matches_literal_without_fold_regexp
    cfg = Onibi::Compiler.compile(Onibi::Parser.parse("cat")).graph
    dfa = Onibi::Automata::DFA.from_tnfa(Onibi::Automata::GlushkovTNFA.from_cfg(cfg))
    program = Onibi::IRGen::YARVIR.generate(dfa)

    assert_equal [2, 5], Onibi::IRGen::YARVIR.execute(program, "xxcatyy", 0)
    assert_nil Onibi::IRGen::YARVIR.execute(program, "xxdogyy", 0)
  end

  def test_public_vm_passes_compiled_execution_facts_without_ast_lookup
    literal = Onibi::Regexp.new("abc")
    nullable = Onibi::Regexp.new("a*")

    literal_flags = literal.send(:bytecode_program).flags
    nullable_flags = nullable.send(:bytecode_program).flags

    assert_equal true, literal_flags[:literal_only]
    assert_equal false, literal_flags[:nullable]
    assert_equal true, nullable_flags[:nullable]
    assert Onibi::Interpreter::Executor
    refute Onibi::IRGen::YARVIR.const_defined?(:Executor, false)
  end

  def test_unicode_capture_offset_fact_is_embedded_in_semantic_bytecode
    literal = Onibi::Regexp.new("é")
    repeated_capture = Onibi::Regexp.new("(é+)")

    assert_equal true, literal.send(:bytecode_program).flags[:unicode_capture_byte_offsets]
    assert_equal false, repeated_capture.send(:bytecode_program).flags[:unicode_capture_byte_offsets]
    refute literal.respond_to?(:bytecode_unicode_capture_byte_offsets?, true)
  end

  def test_literal_casefold_is_embedded_in_semantic_bytecode
    root = Onibi::IRGen::YARVIR::SemanticBytecode.compile(
      Onibi::Parser.parse("ᾀ").ast, casefold: true
    )

    assert_equal "ἀι", root.parts.first.casefold
    assert_equal [%w[ᾀ ἀι]], root.parts.first.casefold_segments
    assert root.parts.first.fold_boundary_sensitive
    assert_equal({ kind: :expanded_tail, tail: "ι", sensitive: true }, root.parts.first.fold_boundary)

    lookahead = Onibi::IRGen::YARVIR::SemanticBytecode.compile(
      Onibi::Parser.parse("ω").ast, casefold: true
    )
    assert_equal :non_split_prefix, lookahead.parts.first.fold_prefix_boundary

    ascii = Onibi::Regexp.new("ss", Onibi::Regexp::IGNORECASE)
    ascii_root = Onibi::IRGen::YARVIR::SemanticBytecode.compile(ascii.ast, casefold: true)
    refute ascii_root.parts.first.fold_boundary_sensitive
    assert_nil ascii_root.parts.first.fold_boundary
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

  def test_dedicated_executor_tracks_a_simple_capture_backreference
    cfg = Onibi::Compiler.compile(Onibi::Parser.parse("(ab)\\1")).graph
    dfa = Onibi::Automata::DFA.from_tnfa(Onibi::Automata::GlushkovTNFA.from_cfg(cfg))
    program = Onibi::IRGen::YARVIR.generate(dfa)

    assert_equal [2, 6, { 1 => [2, 4] }],
                 Onibi::IRGen::YARVIR.execute_with_captures(program, "xxabab", 0)
  end

  def test_program_automaton_contains_semantic_operands
    program = program_for(Onibi::AST::Literal.new("a"))
    labels = program.automaton.transitions.keys.map(&:last)

    assert(labels.all? { |label| semantic_operand?(label[1]) })
    refute(labels.any? { |label| label[1].is_a?(Onibi::AST::Literal) })
    assert_nil program.automaton.tnfa
  end

  def test_ir_generation_is_idempotent_for_semantic_automata
    original = program_for(Onibi::AST::Literal.new("a"))
    regenerated = Onibi::IRGen::YARVIR.generate(original.automaton)

    assert_equal original.instructions, regenerated.instructions
    assert regenerated.instructions.all? do |instruction|
      instruction.opcode != :match || semantic_operand?(instruction.operand[1])
    end
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
      [:start, 0],
      [:match, [:match_literal, Onibi::AST::Literal.new("a")]],
      [:jump, 1],
      [:match, [:match_any, Onibi::AST::Any.new(".")]],
      [:jump, 2], [:accept, 2]
    ]
    assert_equal expected, instruction_signature(program)
  end

  private

  def program_for(node)
    dfa = Onibi::Automata::DFA.from_tnfa(tnfa_for(node))
    Onibi::IRGen::YARVIR.generate(dfa)
  end

  def semantic_root(program)
    program.instructions.find { |instruction| instruction.opcode == :semantic_match }.operand.entry_node
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
    program.instructions.map do |instruction|
      [instruction.opcode, legacy_operand_signature(instruction.operand)]
    end
  end

  def legacy_operand_signature(value)
    return value.map { |item| legacy_operand_signature(item) } if value.is_a?(Array)

    semantic = Onibi::IRGen::YARVIR::SemanticBytecode
    case value
    when semantic::Literal then Onibi::AST::Literal.new(value.value)
    when semantic::CharacterClass then Onibi::AST::CharacterClass.new(value.value)
    when semantic::Escape then Onibi::AST::Escape.new(value.kind)
    when semantic::Property then Onibi::AST::Property.new(value.name, value.negated)
    when semantic::Backreference then Onibi::AST::Backreference.new(value.identifier, value.named)
    when semantic::Assertion then Onibi::AST::Assertion.new(legacy_operand_signature(value.body), value.kind)
    when semantic::Any then Onibi::AST::Any.new(value.value)
    when semantic::Anchor then Onibi::AST::Anchor.new(value.kind)
    when semantic::Sequence then Onibi::AST::Sequence.new(value.parts.map { |part| legacy_operand_signature(part) })
    when semantic::Alternation then Onibi::AST::Alternation.new(value.branches.map { |branch| legacy_operand_signature(branch) })
    when semantic::Group then Onibi::AST::Group.new(legacy_operand_signature(value.body), value.number, value.capture, value.name)
    when semantic::OptionGroup
      Onibi::AST::OptionGroup.new(legacy_operand_signature(value.body), value.ignorecase, value.multiline, value.extended)
    when semantic::AtomicGroup then Onibi::AST::AtomicGroup.new(legacy_operand_signature(value.body))
    when semantic::Conditional
      Onibi::AST::Conditional.new(value.condition, legacy_operand_signature(value.yes_branch), legacy_operand_signature(value.no_branch))
    when semantic::SubexpressionCall then Onibi::AST::SubexpressionCall.new(value.identifier, value.named)
    when semantic::Absence then Onibi::AST::Absence.new(legacy_operand_signature(value.body))
    when semantic::Quantifier
      Onibi::AST::Quantifier.new(legacy_operand_signature(value.expression), value.kind, value.minimum, value.maximum, value.mode)
    else value
    end
  end

  def semantic_operand?(operand)
    operand.is_a?(Onibi::IRGen::YARVIR::SemanticBytecode::Literal)
  end
end
