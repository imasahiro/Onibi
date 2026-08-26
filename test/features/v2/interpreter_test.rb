# frozen_string_literal: true

require "test_helper"

class InterpreterTest < Minitest::Test
  def test_bytecode_spec_declares_each_instruction_transition
    assert_equal %i[start match jump accept], Onibi::Interpreter::BYTECODE_SPEC.fetch(:dfa).keys
    assert_equal %i[nfa_start nfa_match nfa_accept], Onibi::Interpreter::BYTECODE_SPEC.fetch(:tnfa).keys
    assert_equal %i[match_literal match_class match_escape match_property match_any
                    match_assertion test_anchor match_absence match_group match_quantifier
                    match_atomic_group match_backreference match_conditional
                    match_subexpression_call semantic_match match_option_group],
                 Onibi::Interpreter::BYTECODE_SPEC.fetch(:semantic).keys
  end

  def test_bytecode_spec_defines_input_and_state_transition_for_every_opcode
    required = %i[signature operand input stack_transition local_transition
                  cursor_transition control failure]

    Onibi::Interpreter::BYTECODE_SPEC.each_value do |family|
      assert family.frozen?
      family.each_value do |spec|
        assert_empty(required - spec.keys)
        assert_equal %i[operand characters flags], spec[:input].keys
        assert spec.frozen?
        assert spec[:input].frozen?
        assert_includes %i[preserve push_results push_first_result halt], spec[:stack_transition]
        assert_includes %i[preserve merge_result restore_frame_state zero_width_result
                           enter_capture_scope repeat_and_merge commit_scope branch
                           call_and_merge scope_flags set_active_states return_result],
                        spec[:local_transition]
        assert_includes %i[preserve advance_by_result], spec[:cursor_transition]
      end
    end
  end

  def test_bytecode_spec_defines_absence_as_complement_of_wrapped_body
    absence = Onibi::Interpreter::BYTECODE_SPEC.fetch(:semantic).fetch(:match_absence)

    assert_equal :complement_of_wrapped_body, absence.fetch(:language)
    assert_equal ".* body .*", absence.fetch(:wrapped_language)
    assert_equal :ordered_body_candidates, absence.fetch(:preserves)
    assert_equal :execution_frame, absence.fetch(:local)
    assert_equal :probe_with_bounded_end, absence.fetch(:transition)
    assert_equal :repeat_frame_state, absence.fetch(:capture_checkpoint)
  end

  def test_fold_policy_classifies_operand_source_boundaries
    literal = Onibi::IRGen::YARVIR::SemanticBytecode::Literal.new("s", nil, nil, false, nil, nil)
    policy = Onibi::Interpreter::FoldPolicy.new

    assert_equal :exact, policy.classify(literal, "s")
    assert_equal :simple_source, policy.classify(literal, "ſ")
    assert_equal :no_match, policy.classify(literal, "x")
  end

  def test_literal_exposes_source_and_folded_character_widths
    literal = Onibi::IRGen::YARVIR::SemanticBytecode.compile(Onibi::AST::Literal.new("ᾀ"))

    assert_equal 1, literal.source_width
    assert_equal 2, literal.folded_width
  end

  def test_casefold_lengths_accepts_literal_width_metadata
    literal = Onibi::IRGen::YARVIR::SemanticBytecode.compile(Onibi::AST::Literal.new("ᾀ"))
    executor = Onibi::Interpreter::Executor.new(Onibi::Regexp.new("a").send(:bytecode_program))
    characters = Onibi::InputView.new("ἀι").characters

    assert_equal [2], executor.send(:casefold_lengths, literal.value, characters, 0,
                                    folded: literal.casefold,
                                    source_width: literal.source_width,
                                    folded_width: literal.folded_width)
  end

  def test_execution_frame_contains_scope_checkpoint_fields
    frame = Onibi::Interpreter::ExecutionFrame.new(
      kind: :absence,
      absent_start: 0,
      absent_end: 3,
      probe_position: 0,
      possible_points: [[0, {}]],
      body_checkpoints: [[0, [[1, {}]]]],
      capture_checkpoints: []
    )

    assert_equal :absence, frame.kind
    assert_equal [:absence, 0, 3, 0, [[0, {}]], [[0, [[1, {}]]]], []], frame.to_a
    assert_equal 0, frame.scope_start
    assert_equal 3, frame.scope_end
    assert_equal 0, frame.position
    assert_equal [[0, [[1, {}]]]], frame.checkpoints
  end

  def test_execution_state_exposes_explicit_vm_call_and_backtrack_records
    state = Onibi::ExecutionState.new(cursor: 3)
    call = state.push_call(7)
    point = state.push_backtrack_point(11)

    assert_equal [7, 3], [call.return_pc, call.cursor]
    assert_equal [11, 3], [point.pc, point.cursor]
    assert_same point, state.pop_backtrack_point
    assert_same call, state.pop_call
  end

  def test_execution_state_resumes_backtrack_as_semantic_frame
    state = Onibi::ExecutionState.new
    point = state.push_backtrack_point(
      11, cursor: 3, captures: { 1 => [1, 2] }, flags: { ignorecase: true }
    )

    assert_same point, state.resume_backtrack
    frame = state.pop_semantic_frame
    assert_equal [11, 3], [frame.pc, frame.cursor]
    assert_equal({ 1 => [1, 2] }, frame.captures)
    assert_equal({ ignorecase: true }, frame.flags)
    assert_nil state.resume_backtrack
  end

  def test_flat_vm_does_not_enter_tree_evaluator
    program = Onibi::Regexp.new("(a|b)c").send(:bytecode_program)
    flat = program.instructions.find { |instruction| instruction.opcode == :semantic_flat }
    assert flat

    executor = Onibi::Interpreter::Executor.new(program)
    assert_nil executor.instance_variable_get(:@semantic_entry)
    assert_nil executor.instance_variable_get(:@semantic_program)
    assert_instance_of Onibi::Interpreter::FlatExecutor, executor
    refute executor.respond_to?(:tree_results)
    assert_equal [0, 2], executor.match("ac")
  end

  def test_flat_assertion_and_absence_do_not_enter_tree_evaluator
    [
      ["(?=a[0-9])a[0-9]", "a7"],
      ["((?~[a-z]))", "12a"]
    ].each do |pattern, input|
      program = Onibi::Regexp.new(pattern).send(:bytecode_program)
      assert(program.instructions.any? { |instruction| instruction.opcode == :semantic_flat })
      executor = Onibi::Interpreter::Executor.new(program)
      refute executor.respond_to?(:tree_results)
      assert executor.match(input)
    end
  end

  def test_interpreter_executes_dfa_start_match_jump_and_accept
    program = dfa_program_for("ab")

    assert_equal [2, 4], Onibi::Interpreter::Executor.new(program).match("xxabyy")
    assert_equal %i[start match jump accept], program.instructions.map(&:opcode)
  end

  def test_interpreter_executes_tnfa_start_match_and_accept
    program = nfa_program_for("ab")

    assert_equal [2, 4], Onibi::Interpreter::Executor.new(program).match("xxabyy")
    assert_equal :nfa_start, program.instructions.first.opcode
    assert_equal :nfa_match, program.instructions[1].opcode
    assert_equal :nfa_accept, program.instructions.last.opcode
  end

  def test_interpreter_evaluates_semantic_operands_with_stack_results
    regexp = Onibi::Regexp.new("(?<word>[a-z]+)")
    program = regexp.send(:bytecode_program)

    result = Onibi::Interpreter::Executor.new(program).match_with_captures("--abc--")

    assert_equal [2, 5], result.first(2)
    assert_equal({ 1 => [2, 5], "word" => [2, 5] }, result[2])
  end

  def test_flat_vm_never_enters_compatibility_tree_evaluator
    regexp = Onibi::Regexp.new("(a|b)c")
    executor = Onibi::Interpreter::Executor.new(regexp.send(:bytecode_program))

    assert_equal [0, 2], executor.match("ac")
  end

  def test_executor_selects_flat_subclass_for_single_character_unicode_fold
    regexp = Onibi::Regexp.new("(?i:ß)")
    executor = Onibi::Interpreter::Executor.new(regexp.send(:bytecode_program))

    assert_instance_of Onibi::Interpreter::FlatExecutor, executor
    refute_respond_to executor, :tree_results
    assert_equal [0, 2], executor.match("ss")
  end

  def test_executor_uses_flat_vm_for_safe_scoped_unicode_casefold
    regexp = Onibi::Regexp.new("(?i:é)")
    program = regexp.send(:bytecode_program)

    assert(program.instructions.any? { |instruction| instruction.opcode == :semantic_flat })
    refute(program.instructions.any? { |instruction| instruction.opcode == :semantic_vm })
    assert_equal [0, 1], Onibi::Interpreter::Executor.new(program).match("É")
  end

  def test_executor_uses_flat_vm_for_scoped_ascii_predicate
    regexp = Onibi::Regexp.new("(?i:[0-9])")
    program = regexp.send(:bytecode_program)

    assert(program.instructions.any? { |instruction| instruction.opcode == :semantic_flat })
    assert_equal [0, 1], Onibi::Interpreter::Executor.new(program).match("7")
  end

  def test_executor_uses_flat_vm_for_scoped_ascii_property
    regexp = Onibi::Regexp.new("(?i:\\p{ASCII})")
    program = regexp.send(:bytecode_program)

    assert(program.instructions.any? { |instruction| instruction.opcode == :semantic_flat })
    assert_equal [0, 1], Onibi::Interpreter::Executor.new(program).match("Z")
  end

  def test_executor_uses_flat_vm_for_scoped_ascii_hex_property
    regexp = Onibi::Regexp.new("(?i:\\p{ASCII_Hex_Digit})")
    program = regexp.send(:bytecode_program)

    assert(program.instructions.any? { |instruction| instruction.opcode == :semantic_flat })
    assert_equal [0, 1], Onibi::Interpreter::Executor.new(program).match("f")
  end

  def test_executor_uses_flat_vm_for_ascii_hex_property_aliases
    %w[XDigit Hex_Digit].each do |property|
      program = Onibi::Regexp.new("(?i:\\p{#{property}})").send(:bytecode_program)

      assert program.instructions.any? { |instruction| instruction.opcode == :semantic_flat }, property
      assert_equal [0, 1], Onibi::Interpreter::Executor.new(program).match("F"), property
    end
  end

  def test_executor_uses_flat_vm_for_fold_invariant_digit_property
    regexp = Onibi::Regexp.new("(?i:\\p{Digit})")
    program = regexp.send(:bytecode_program)

    assert(program.instructions.any? { |instruction| instruction.opcode == :semantic_flat })
    assert_equal [0, 1], Onibi::Interpreter::Executor.new(program).match("٤")
  end

  def test_executor_uses_flat_vm_for_fold_invariant_properties
    { "Punct" => "!", "Space" => " ", "Blank" => "\t", "Cntrl" => "\u0001" }.each do |property, input|
      program = Onibi::Regexp.new("(?i:\\p{#{property}})").send(:bytecode_program)

      assert program.instructions.any? { |instruction| instruction.opcode == :semantic_flat }, property
      assert_equal [0, 1], Onibi::Interpreter::Executor.new(program).match(input), property
    end
  end

  def test_executor_uses_flat_vm_for_metadata_proven_fold_invariant_property
    { "White_Space" => "\u2003", "Pattern_Syntax" => "!", "Mark" => "\u0301" }.each do |property, input|
      program = Onibi::Regexp.new("(?i:\\p{#{property}})").send(:bytecode_program)

      assert program.instructions.any? { |instruction| instruction.opcode == :semantic_flat }, property
      assert_equal [0, 1], Onibi::Interpreter::Executor.new(program).match(input), property
    end
  end

  def test_executor_uses_flat_vm_for_fixed_width_unicode_class_fold
    { "é" => "É", "Α" => "α" }.each do |source, input|
      program = Onibi::Regexp.new("(?i:[#{source}])").send(:bytecode_program)

      assert program.instructions.any? { |instruction| instruction.opcode == :semantic_flat }, source
      assert_equal [0, 1], Onibi::Interpreter::Executor.new(program).match(input), source
    end
  end

  def test_executor_uses_flat_vm_for_terminal_boundary_sensitive_fold
    program = Onibi::Regexp.new("(?i:ᾀ)").send(:bytecode_program)

    assert(program.instructions.any? { |instruction| instruction.opcode == :semantic_flat })
    assert_equal [0, 2], Onibi::Interpreter::Executor.new(program).match("ἀι")
  end

  def test_executor_uses_flat_vm_for_boundary_fold_with_end_anchor
    regexp = Onibi::Regexp.new("(?i:ᾀ)\\z")
    program = regexp.send(:bytecode_program)

    assert(program.instructions.any? { |instruction| instruction.opcode == :semantic_flat })
    assert_equal [0, 2], Onibi::Interpreter::Executor.new(program).match("ἀι")
    assert_nil Onibi::Interpreter::Executor.new(program).match("ᾀ")
    assert_nil Onibi::Interpreter::Executor.new(program).match("ἀιx")
  end

  def test_flat_fold_boundary_uses_next_fold_metadata
    root = Onibi::IRGen::YARVIR::SemanticBytecode.compile(
      Onibi::Parser.parse("(?i:ᾀ)ι").ast
    )
    flat = Onibi::IRGen::YARVIR::SemanticBytecode.lower(root).flat_program
    program = Onibi::IRGen::YARVIR::Program.new(
      instructions: [Onibi::IRGen::YARVIR::Instruction.new(opcode: :semantic_flat, operand: flat)],
      flags: { encoding: Encoding::UTF_8, tagged_vm: true }
    )

    assert_nil program.execute("ᾀι")
    assert_equal [0, 2], program.execute("ᾀιι")
    assert_equal [0, 3], program.execute("ἀιι")
  end

  def test_executor_uses_flat_vm_for_boundary_fold_with_start_anchor
    regexp = Onibi::Regexp.new("\\A(?i:ᾀ)")
    program = regexp.send(:bytecode_program)

    assert(program.instructions.any? { |instruction| instruction.opcode == :semantic_flat })
    assert_equal [0, 2], Onibi::Interpreter::Executor.new(program).match("ἀι")
    assert_nil Onibi::Interpreter::Executor.new(program).match("xἀι")
  end

  def test_executor_uses_flat_vm_for_boundary_fold_with_negative_end_lookahead
    regexp = Onibi::Regexp.new("(?i:ᾀ)(?!\\z)")
    program = regexp.send(:bytecode_program)

    assert(program.instructions.any? { |instruction| instruction.opcode == :semantic_flat })
    assert_equal [0, 2], Onibi::Interpreter::Executor.new(program).match("ἀιx")
    assert_equal [0, 1], Onibi::Interpreter::Executor.new(program).match("ᾀx")
    assert_nil Onibi::Interpreter::Executor.new(program).match("ἀι")
    assert_nil Onibi::Interpreter::Executor.new(program).match("ᾀ")
  end

  def test_executor_uses_flat_vm_for_trailing_anchor_lookahead
    positive = Onibi::Regexp.new("a(?=\\z)").send(:bytecode_program)
    negative = Onibi::Regexp.new("a(?!\\z)").send(:bytecode_program)

    [positive, negative].each do |program|
      assert(program.instructions.any? { |instruction| instruction.opcode == :semantic_flat })
    end
    assert_equal [0, 1], Onibi::Interpreter::Executor.new(positive).match("a")
    assert_nil Onibi::Interpreter::Executor.new(positive).match("ax")
    assert_nil Onibi::Interpreter::Executor.new(negative).match("a")
    assert_equal [0, 1], Onibi::Interpreter::Executor.new(negative).match("ax")
  end

  def test_executor_rebuilds_input_view_for_each_input
    program = Onibi::Regexp.new("(?i:ᾀ)").send(:bytecode_program)
    executor = Onibi::Interpreter::Executor.new(program)

    assert_equal [0, 1], executor.match("ᾀ")
    assert_equal [0, 2], executor.match("ἀι")
  end

  def test_execution_state_has_a_dedicated_absence_frame
    state = Onibi::ExecutionState.new
    frame = state.push_absence_frame(
      resume_pc: 4,
      body_pc: 7,
      absent_start: 1,
      absent_end: 5,
      probe_position: 1,
      possible_points: [],
      body_checkpoints: [],
      capture_checkpoints: [],
      branch_checkpoints: [[1, 0, 1]],
      preferred_branch: 1
    )

    assert_instance_of Onibi::ExecutionState::AbsenceFrame, frame
    assert_equal 4, frame.resume_pc
    assert_equal 7, frame.body_pc
    assert_equal [[1, 0, 1]], frame.branch_checkpoints
    assert_equal 1, frame.preferred_branch
    assert_equal frame, state.current_frame
  end

  def test_absence_checkpoint_records_ordered_branch_results
    executor = Onibi::Interpreter::Executor.new(Onibi::Regexp.new("a").send(:bytecode_program))
    frame = Onibi::ExecutionState::AbsenceFrame.new(
      kind: :absence, possible_points: [], body_checkpoints: [], capture_checkpoints: [],
      branch_checkpoints: [], preferred_branch: nil
    )

    executor.send(:record_absence_checkpoint, frame, 2,
                  [[1, { __match_alternative_index: 3 }], [2, { __match_alternative_index: 4 }]], {})

    assert_equal [[2, 3, 1], [2, 4, 2]], frame.branch_checkpoints
    assert_equal 3, frame.preferred_branch
    frame.record_branch_checkpoint(3, 5, 1)
    assert_equal [3, 5, 1], frame.branch_checkpoints.last
    assert_equal 3, frame.preferred_branch
    assert_equal [[2, 3, 1], [2, 4, 2]], frame.branch_checkpoints_at(2)
    assert_equal 3, frame.preferred_branch_at(2)
    assert_equal [1, { __match_alternative_index: 3 }],
                 frame.preferred_body_result(2, [[1, { __match_alternative_index: 3 }]])
    frame.absent_end = 8
    frame.tighten_absent_end(5)
    frame.tighten_absent_end(6)
    assert_equal 5, frame.absent_end
    frame.record_body_checkpoint(4, [[1, {}]], {})
    assert_equal [[4, {}]], frame.possible_points.last(1)
    assert_equal [[4, [[1, {}]]]], frame.body_checkpoints.last(1)
  end

  def test_absence_capture_checkpoint_restores_latest_non_discarded_state
    executor = Onibi::Interpreter::Executor.new(Onibi::Regexp.new("a").send(:bytecode_program))
    frame = Onibi::ExecutionState::AbsenceFrame.new(
      kind: :absence, possible_points: [], body_checkpoints: [], capture_checkpoints: [
        [1, 1, { 1 => [1, 2] }, true, false],
        [2, 1, { 1 => [2, 3] }, false, true]
      ], branch_checkpoints: [], preferred_branch: nil
    )

    assert_equal({ 1 => [2, 3] }, executor.send(:absence_capture_checkpoint_state, frame, {}))
    assert_equal [2, 1, { 1 => [2, 3] }, false, true],
                 frame.restorable_capture_checkpoint(require_ambiguous: true)
    frame.record_capture_checkpoint(3, 2, { 1 => [3, 5] }, false, false)
    assert_equal [3, 2, { 1 => [3, 5] }, false, false], frame.capture_checkpoints.last
  end

  def test_execution_state_capture_frame_records_span
    state = Onibi::ExecutionState.new
    frame = state.start_capture(number: 1, name: "word", start: 2)
    captures = {}

    assert_instance_of Onibi::ExecutionState::CaptureFrame, frame
    assert_equal [2, 5], state.commit_capture(captures, frame, finish: 5)
    assert_equal({ 1 => [2, 5], "word" => [2, 5] }, captures)
    assert_empty state.capture_frames
  end

  def test_execution_state_restores_capture_frames_with_semantic_frame
    state = Onibi::ExecutionState.new
    state.start_capture(number: 1, start: 3)
    state.push_semantic_frame(
      Onibi::ExecutionState::SemanticFrame.new(pc: 2, cursor: 3, captures: {}, flags: {})
    )
    state.capture_frames.clear

    state.pop_semantic_frame

    assert_equal 1, state.active_capture_frame(1).number
    assert_equal 3, state.active_capture_frame(1).start
  end

  def test_bytecode_program_embeds_semantic_operands_without_ast_nodes
    regexp = Onibi::Regexp.new("(?<word>[a-z]+)(?(<word>)!|c)")
    program = regexp.send(:bytecode_program)

    refute(program.instructions.any? { |instruction| instruction.opcode == :semantic_match })
    assert(program.instructions.any? { |instruction| instruction.opcode == :semantic_flat })
    refute program.flags.key?(:subexpressions)
    assert(program.instructions.all? { |instruction| semantic_node?(instruction.operand) })
    assert program.tree_free?
  end

  def test_interpreter_executes_each_semantic_operand_kind
    cases = [
      ["a", "a"], ["[a]", "a"], ["\\d", "7"], ["\\p{Alpha}", "A"],
      [".", "x"], ["(?=a)a", "a"], ["\\Aa", "a"], ["(?~a)", "b"],
      ["(a)", "a"], ["a+", "aa"], ["(?>a)", "a"], ["(a)\\1", "aa"],
      ["(a)?(?(1)b|c)", "ab"], ["(a)\\g<1>", "aa"], ["(?i:a)", "A"]
    ]

    cases.each do |pattern, input|
      regexp = Onibi::Regexp.new(pattern)
      result = Onibi::Interpreter::Executor.new(regexp.send(:bytecode_program)).match(input)

      assert_equal [0, input.length], result, pattern
    end
  end

  def test_interpreter_keeps_alternation_branch_identity_in_semantic_state
    regexp = Onibi::Regexp.new("(?~(?:.*(ab|a)))")
    program = regexp.send(:bytecode_program)
    executor = Onibi::Interpreter::Executor.new(program)
    refute program.instructions.any? { |instruction| instruction.opcode == :semantic_match }
    assert_equal [0, 2], executor.match("aba")
  end

  def test_absence_literal_fast_path_preserves_wrapped_capture
    program = Onibi::Regexp.new("(?~(a))").send(:bytecode_program)
    refute(program.instructions.any? { |instruction| instruction.opcode == :semantic_match })

    expected = ::Regexp.new("(?~(a))").match("ba")
    actual = Onibi::Regexp.new("(?~(a))").match("ba")

    assert_equal [expected[0], expected.captures, expected.offset(1)],
                 [actual[0], actual.captures, actual.offset(1)]
  end

  def test_absence_repeat_uses_flat_vm
    regexp = Onibi::Regexp.new("(?~a)+")
    program = regexp.send(:bytecode_program)

    refute(program.instructions.any? { |instruction| instruction.opcode == :semantic_match })
    ["a", "b", "ba", "bbb"].each do |input|
      expected = ::Regexp.new("(?~a)+").match(input)
      assert_equal [expected&.to_a, expected&.offset(0)],
                   [regexp.match(input)&.to_a, regexp.match(input)&.offset(0)]
    end
  end

  def test_nullable_literal_absence_repeat_uses_flat_vm
    regexp = Onibi::Regexp.new("(?~a*)")
    program = regexp.send(:bytecode_program)

    refute(program.instructions.any? { |instruction| instruction.opcode == :semantic_match })
    ["b", "ab", "aab", "aaab", "aaaa"].each do |input|
      expected = ::Regexp.new("(?~a*)").match(input)
      actual = regexp.match(input)
      assert_equal [expected&.to_a, expected&.offset(0)],
                   [actual&.to_a, actual&.offset(0)], input
    end
  end

  def test_negative_lookahead_absence_uses_flat_vm
    regexp = Onibi::Regexp.new("(?~(?!a))")
    program = regexp.send(:bytecode_program)

    refute(program.instructions.any? { |instruction| instruction.opcode == :semantic_match })
    ["a", "ab", "ba", "b", "aa", "bb", "bba"].each do |input|
      expected = ::Regexp.new("(?~(?!a))").match(input)
      actual = regexp.match(input)
      assert_equal [expected&.to_a, expected&.offset(0)],
                   [actual&.to_a, actual&.offset(0)], input
    end
  end

  def test_negative_lookahead_absence_with_suffix_uses_flat_vm
    source = "(?~(?!a))b"
    regexp = Onibi::Regexp.new(source)
    program = regexp.send(:bytecode_program)

    refute(program.instructions.any? { |instruction| instruction.opcode == :semantic_match })
    ["a", "ab", "ba", "b", "x", "aa", "bb", "bba"].each do |input|
      expected = ::Regexp.new(source).match(input)
      actual = regexp.match(input)
      assert_equal [expected&.to_a, expected&.offset(0)],
                   [actual&.to_a, actual&.offset(0)], input
    end
  end

  def test_simple_capture_absence_with_literal_suffix_uses_flat_vm
    ["(?~(a))b", "(?~(a|b))c"].each do |source|
      regexp = Onibi::Regexp.new(source)
      program = regexp.send(:bytecode_program)

      refute(program.instructions.any? { |instruction| instruction.opcode == :semantic_match })
      ["a", "ab", "b", "ba", "abc", "xbc", "xac"].each do |input|
        expected = ::Regexp.new(source).match(input)
        actual = regexp.match(input)
        assert_equal [expected&.to_a, expected&.offset(0)],
                     [actual&.to_a, actual&.offset(0)], [source, input]
      end
    end
  end

  def test_absence_literal_alternation_capture_uses_flat_vm
    regexp = Onibi::Regexp.new("(?~(a|b))")
    program = regexp.send(:bytecode_program)

    refute(program.instructions.any? { |instruction| instruction.opcode == :semantic_match })
    match = regexp.match("xaby")
    assert_equal "x", match[0]
    assert_equal "a", match[1]
  end

  def test_capture_free_wildcard_literal_absence_uses_flat_probe
    [".*a", ".*aa", ".*[a]", ".*\\d", ".*(?:ab|a)", ".*a+"].each do |body|
      source = "(?~(?:#{body}))"
      regexp = Onibi::Regexp.new(source)
      program = regexp.send(:bytecode_program)

      refute(program.instructions.any? { |instruction| instruction.opcode == :semantic_match })
      assert(program.instructions.any? { |instruction| instruction.opcode == :semantic_flat })
      ["a", "aa", "aaa", "aaaa", "aaaaa", "ba", "baa", "ababa"].each do |input|
        expected = ::Regexp.new(source).match(input)
        actual = regexp.match(input)
        assert_equal [expected&.to_a, expected&.offset(0)],
                     [actual&.to_a, actual&.offset(0)], [source, input]
      end
    end
  end

  def test_single_literal_capture_wildcard_absence_uses_flat_probe
    source = "(?~(?:.*(a)))"
    regexp = Onibi::Regexp.new(source)
    program = regexp.send(:bytecode_program)

    refute(program.instructions.any? { |instruction| instruction.opcode == :semantic_match })
    ["a", "aa", "ba", "ababa"].each do |input|
      expected = ::Regexp.new(source).match(input)
      actual = regexp.match(input)
      assert_equal [expected&.to_a, expected&.offset(0)],
                   [actual&.to_a, actual&.offset(0)], input
    end
  end

  def test_single_literal_alternation_capture_wildcard_absence_uses_flat_probe
    source = "(?~(?:.*(a|b)))"
    regexp = Onibi::Regexp.new(source)
    program = regexp.send(:bytecode_program)

    refute(program.instructions.any? { |instruction| instruction.opcode == :semantic_match })
    ["a", "b", "ab", "ba", "caba"].each do |input|
      expected = ::Regexp.new(source).match(input)
      actual = regexp.match(input)
      assert_equal [expected&.to_a, expected&.offset(0)],
                   [actual&.to_a, actual&.offset(0)], input
    end
  end

  def test_wildcard_capture_probe_with_internal_suffix_uses_partial_checkpoint
    ["(?~(?:.*(a)c))", "(?~(?:.*(a|b)c))"].each do |source|
      regexp = Onibi::Regexp.new(source)
      program = regexp.send(:bytecode_program)

      refute(program.instructions.any? { |instruction| instruction.opcode == :semantic_match })
      ["a", "ac", "abc", "bac", "cabc", "caba", "ba", "ab"].each do |input|
        expected = ::Regexp.new(source).match(input)
        actual = regexp.match(input)
        assert_equal [expected&.to_a, expected&.offset(0)],
                     [actual&.to_a, actual&.offset(0)], [source, input]
      end
    end
  end

  def test_absence_followed_by_match_reset_keeps_zero_width_result
    expected = ::Regexp.new("a(?~a)\\K").match("abc")
    actual = Onibi::Regexp.new("a(?~a)\\K").match("abc")

    assert_equal [expected[0], expected.offset(0)], [actual[0], actual.offset(0)]

    expected = ::Regexp.new("\\K(?~a)+", ::Regexp::IGNORECASE).match("ba")
    actual = Onibi::Regexp.new("\\K(?~a)+", Onibi::Regexp::IGNORECASE).match("ba")
    assert_equal [expected[0], expected.offset(0)], [actual[0], actual.offset(0)]
  end

  def test_greedy_negated_class_does_not_backtrack_into_scoped_casefold
    expected = ::Regexp.new("[^a]+(?i:a)").match("AAB")
    actual = Onibi::Regexp.new("[^a]+(?i:a)").match("AAB")

    assert_nil expected
    assert_nil actual
  end

  def test_sharp_s_class_split_respects_following_fold_boundary
    ["[ß]ß", "[ß]ss"].each do |source|
      expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match("sß")
      actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match("sß")

      assert_equal [expected&.to_a, expected&.offset(0)], [actual&.to_a, actual&.offset(0)], source
    end
  end

  def test_folded_optional_literal_keeps_consuming_branch_before_assertion_repeat
    expected = ::Regexp.new("ς?(?!ß){1}", ::Regexp::IGNORECASE).match("ς")
    actual = Onibi::Regexp.new("ς?(?!ß){1}", Onibi::Regexp::IGNORECASE).match("ς")

    assert_equal [expected&.to_a, expected&.offset(0)], [actual&.to_a, actual&.offset(0)]
  end

  def test_binary_input_does_not_force_invalid_bytes_through_unicode_fold
    input = "\xE5\x1D".b
    expected = ::Regexp.new("a", ::Regexp::IGNORECASE).match?(input)
    actual = Onibi::Regexp.new("a", Onibi::Regexp::IGNORECASE).match?(input)

    assert_equal expected, actual
  end

  def test_full_fold_literal_sequence_uses_one_flat_operand
    regexp = Onibi::Regexp.new("ss", Onibi::Regexp::IGNORECASE)
    program = regexp.send(:bytecode_program)

    refute(program.instructions.any? { |instruction| instruction.opcode == :semantic_match })
    assert_equal ["ß"], regexp.match("ß")&.to_a
    assert_equal ::Regexp.new("ss", ::Regexp::IGNORECASE).match("ß")&.to_a,
                 regexp.match("ß")&.to_a
  end

  def test_full_fold_character_class_uses_flat_vm
    regexp = Onibi::Regexp.new("[ß]", Onibi::Regexp::IGNORECASE)
    program = regexp.send(:bytecode_program)

    refute(program.instructions.any? { |instruction| instruction.opcode == :semantic_match })
    assert_equal ::Regexp.new("[ß]", ::Regexp::IGNORECASE).match("SS")&.to_a,
                 regexp.match("SS")&.to_a
  end

  def test_casefold_invariant_property_uses_flat_vm
    regexp = Onibi::Regexp.new("\\p{ASCII}", Onibi::Regexp::IGNORECASE)
    program = regexp.send(:bytecode_program)

    refute(program.instructions.any? { |instruction| instruction.opcode == :semantic_match })
    assert regexp.match?("A")
    refute regexp.match?("é")
  end

  def test_casefold_invariant_escape_uses_flat_vm
    ["\\d", "\\w"].each do |source|
      regexp = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE)
      program = regexp.send(:bytecode_program)

      refute(program.instructions.any? { |instruction| instruction.opcode == :semantic_match })
      assert_equal ::Regexp.new(source, ::Regexp::IGNORECASE).match("5")&.to_a,
                   regexp.match("5")&.to_a
    end
  end

  def test_casefold_boundary_escape_uses_flat_vm
    ["\\b", "\\B"].each do |source|
      regexp = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE)
      program = regexp.send(:bytecode_program)

      refute(program.instructions.any? { |instruction| instruction.opcode == :semantic_match })
      expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match(" a")&.offset(0)
      assert_equal expected, regexp.match(" a")&.offset(0)
    end
  end

  def test_scoped_ascii_class_uses_flat_vm
    regexp = Onibi::Regexp.new("(?i:[a-z])")
    program = regexp.send(:bytecode_program)

    refute(program.instructions.any? { |instruction| instruction.opcode == :semantic_match })
    assert_equal ::Regexp.new("(?i:[a-z])").match("K")&.to_a,
                 regexp.match("K")&.to_a
  end

  def test_scoped_ascii_class_without_fold_boundary_keeps_flat_suffix
    regexp = Onibi::Regexp.new("(?i:[a-c])x")
    program = regexp.send(:bytecode_program)

    refute(program.instructions.any? { |instruction| instruction.opcode == :semantic_match })
    assert_equal ::Regexp.new("(?i:[a-c])x").match("Ax")&.to_a,
                 regexp.match("Ax")&.to_a
  end

  def test_scoped_invariant_escape_keeps_flat_suffix
    regexp = Onibi::Regexp.new("(?i:\\d)x")
    program = regexp.send(:bytecode_program)

    refute(program.instructions.any? { |instruction| instruction.opcode == :semantic_match })
    assert_equal ::Regexp.new("(?i:\\d)x").match("5x")&.to_a,
                 regexp.match("5x")&.to_a
  end

  def test_scoped_ascii_full_fold_literal_uses_flat_vm
    regexp = Onibi::Regexp.new("(?i:ss)")
    program = regexp.send(:bytecode_program)

    refute(program.instructions.any? { |instruction| instruction.opcode == :semantic_match })
    assert_equal ::Regexp.new("(?i:ss)").match("ß")&.to_a,
                 regexp.match("ß")&.to_a
  end

  def test_scoped_full_fold_class_uses_flat_vm
    regexp = Onibi::Regexp.new("(?i:[ß])")
    program = regexp.send(:bytecode_program)

    refute(program.instructions.any? { |instruction| instruction.opcode == :semantic_match })
    assert_equal ::Regexp.new("(?i:[ß])").match("SS")&.to_a,
                 regexp.match("SS")&.to_a
  end

  def test_scoped_unicode_property_uses_flat_vm
    regexp = Onibi::Regexp.new("(?i:\\p{Letter})")
    program = regexp.send(:bytecode_program)

    refute(program.instructions.any? { |instruction| instruction.opcode == :semantic_match })
    assert_equal ::Regexp.new("(?i:\\p{Letter})").match("あ")&.to_a,
                 regexp.match("あ")&.to_a
  end

  def test_scoped_unicode_property_ascii_suffix_uses_flat_vm
    regexp = Onibi::Regexp.new("(?i:\\p{Letter})x")
    program = regexp.send(:bytecode_program)

    refute(program.instructions.any? { |instruction| instruction.opcode == :semantic_match })
    assert_equal ::Regexp.new("(?i:\\p{Letter})x").match("ſx")&.to_a,
                 regexp.match("ſx")&.to_a
  end

  def test_scoped_unicode_property_multiple_ascii_suffixes_uses_flat_vm
    regexp = Onibi::Regexp.new("(?i:\\p{Letter})xy")
    program = regexp.send(:bytecode_program)

    refute(program.instructions.any? { |instruction| instruction.opcode == :semantic_match })
    assert_equal ::Regexp.new("(?i:\\p{Letter})xy").match("ſxy")&.to_a,
                 regexp.match("ſxy")&.to_a
  end

  def test_scoped_unicode_property_quantifier_uses_flat_vm
    regexp = Onibi::Regexp.new("(?i:\\p{Letter})+")
    program = regexp.send(:bytecode_program)

    refute(program.instructions.any? { |instruction| instruction.opcode == :semantic_match })
    assert_equal ::Regexp.new("(?i:\\p{Letter})+").match("ſſ")&.to_a,
                 regexp.match("ſſ")&.to_a
  end

  def test_scoped_unicode_property_alternation_uses_flat_vm
    regexp = Onibi::Regexp.new("(?i:\\p{Letter}|\\p{Number})")
    program = regexp.send(:bytecode_program)

    refute(program.instructions.any? { |instruction| instruction.opcode == :semantic_match })
    assert_equal ::Regexp.new("(?i:\\p{Letter}|\\p{Number})").match("ſ")&.to_a,
                 regexp.match("ſ")&.to_a
    assert_equal ::Regexp.new("(?i:\\p{Letter}|\\p{Number})").match("7")&.to_a,
                 regexp.match("7")&.to_a
  end

  def test_scoped_unicode_property_alternation_ascii_suffix_uses_flat_vm
    regexp = Onibi::Regexp.new("(?i:\\p{Letter}|\\p{Number})x")
    program = regexp.send(:bytecode_program)

    refute(program.instructions.any? { |instruction| instruction.opcode == :semantic_match })
    assert_equal ::Regexp.new("(?i:\\p{Letter}|\\p{Number})x").match("ſx")&.to_a,
                 regexp.match("ſx")&.to_a
    assert_equal ::Regexp.new("(?i:\\p{Letter}|\\p{Number})x").match("7x")&.to_a,
                 regexp.match("7x")&.to_a
  end

  def test_scoped_unicode_property_fixed_quantifier_ascii_suffix_uses_flat_vm
    regexp = Onibi::Regexp.new("(?i:\\p{Letter}){2}x")
    program = regexp.send(:bytecode_program)

    refute(program.instructions.any? { |instruction| instruction.opcode == :semantic_match })
    assert_equal ::Regexp.new("(?i:\\p{Letter}){2}x").match("ſſx")&.to_a,
                 regexp.match("ſſx")&.to_a
  end

  def test_scoped_unicode_property_optional_ascii_suffix_uses_flat_vm
    regexp = Onibi::Regexp.new("(?i:\\p{Letter})?x")
    program = regexp.send(:bytecode_program)

    refute(program.instructions.any? { |instruction| instruction.opcode == :semantic_match })
    assert_equal ::Regexp.new("(?i:\\p{Letter})?x").match("ſx")&.to_a,
                 regexp.match("ſx")&.to_a
    assert_equal ::Regexp.new("(?i:\\p{Letter})?x").match("x")&.to_a,
                 regexp.match("x")&.to_a
  end

  def test_scoped_unicode_property_bounded_quantifier_ascii_suffix_uses_flat_vm
    regexp = Onibi::Regexp.new("(?i:\\p{Letter}){2,3}x")
    program = regexp.send(:bytecode_program)

    refute(program.instructions.any? { |instruction| instruction.opcode == :semantic_match })
    assert_equal ::Regexp.new("(?i:\\p{Letter}){2,3}x").match("ſſſx")&.to_a,
                 regexp.match("ſſſx")&.to_a
  end

  def test_scoped_unicode_property_alternation_quantifier_uses_flat_vm
    regexp = Onibi::Regexp.new("(?i:(?:\\p{Letter}|\\p{Number})){2}x")
    program = regexp.send(:bytecode_program)

    refute(program.instructions.any? { |instruction| instruction.opcode == :semantic_match })
    assert_equal ::Regexp.new("(?i:(?:\\p{Letter}|\\p{Number})){2}x").match("ſ7x")&.to_a,
                 regexp.match("ſ7x")&.to_a
  end

  def test_scoped_property_ascii_literal_alternation_uses_flat_vm
    regexp = Onibi::Regexp.new("(?i:(?:\\p{Letter}|a))x")
    program = regexp.send(:bytecode_program)

    refute(program.instructions.any? { |instruction| instruction.opcode == :semantic_match })
    assert_equal ::Regexp.new("(?i:(?:\\p{Letter}|a))x").match("ſx")&.to_a,
                 regexp.match("ſx")&.to_a
    assert_equal ::Regexp.new("(?i:(?:\\p{Letter}|a))x").match("ax")&.to_a,
                 regexp.match("ax")&.to_a
  end

  def test_scoped_mixed_alternation_optional_suffix_uses_flat_vm
    regexp = Onibi::Regexp.new("(?i:(?:\\p{Letter}|a))?x")
    program = regexp.send(:bytecode_program)

    refute(program.instructions.any? { |instruction| instruction.opcode == :semantic_match })
    assert_equal ::Regexp.new("(?i:(?:\\p{Letter}|a))?x").match("ſx")&.to_a,
                 regexp.match("ſx")&.to_a
    assert_equal ::Regexp.new("(?i:(?:\\p{Letter}|a))?x").match("x")&.to_a,
                 regexp.match("x")&.to_a
  end

  def test_scoped_unicode_property_star_ascii_suffix_uses_flat_vm
    regexp = Onibi::Regexp.new("(?i:\\p{Letter})*x")
    program = regexp.send(:bytecode_program)

    refute(program.instructions.any? { |instruction| instruction.opcode == :semantic_match })
    assert_equal ::Regexp.new("(?i:\\p{Letter})*x").match("ſſx")&.to_a,
                 regexp.match("ſſx")&.to_a
    assert_equal ::Regexp.new("(?i:\\p{Letter})*x").match("x")&.to_a,
                 regexp.match("x")&.to_a
  end

  def test_scoped_mixed_alternation_star_ascii_suffix_uses_flat_vm
    regexp = Onibi::Regexp.new("(?i:(?:\\p{Letter}|a))*x")
    program = regexp.send(:bytecode_program)

    refute(program.instructions.any? { |instruction| instruction.opcode == :semantic_match })
    assert_equal ::Regexp.new("(?i:(?:\\p{Letter}|a))*x").match("ſax")&.to_a,
                 regexp.match("ſax")&.to_a
    assert_equal ::Regexp.new("(?i:(?:\\p{Letter}|a))*x").match("x")&.to_a,
                 regexp.match("x")&.to_a
  end

  def test_scoped_mixed_alternation_bounded_optional_suffix_uses_flat_vm
    regexp = Onibi::Regexp.new("(?i:(?:\\p{Letter}|a)){0,3}x")
    program = regexp.send(:bytecode_program)

    refute(program.instructions.any? { |instruction| instruction.opcode == :semantic_match })
    assert_equal ::Regexp.new("(?i:(?:\\p{Letter}|a)){0,3}x").match("ſax")&.to_a,
                 regexp.match("ſax")&.to_a
    assert_equal ::Regexp.new("(?i:(?:\\p{Letter}|a)){0,3}x").match("x")&.to_a,
                 regexp.match("x")&.to_a
  end

  def test_scoped_unicode_property_lazy_bounded_suffix_uses_flat_vm
    regexp = Onibi::Regexp.new("(?i:\\p{Letter}){0,3}?x")
    program = regexp.send(:bytecode_program)

    refute(program.instructions.any? { |instruction| instruction.opcode == :semantic_match })
    assert_equal ::Regexp.new("(?i:\\p{Letter}){0,3}?x").match("ſſx")&.to_a,
                 regexp.match("ſſx")&.to_a
    assert_equal ::Regexp.new("(?i:\\p{Letter}){0,3}?x").match("x")&.to_a,
                 regexp.match("x")&.to_a
  end

  def test_scoped_unicode_property_ascii_escape_sequence_uses_flat_vm
    regexp = Onibi::Regexp.new("(?i:\\p{Letter}\\d)x")
    program = regexp.send(:bytecode_program)

    refute(program.instructions.any? { |instruction| instruction.opcode == :semantic_match })
    assert_equal ::Regexp.new("(?i:\\p{Letter}\\d)x").match("ſ7x")&.to_a,
                 regexp.match("ſ7x")&.to_a
  end

  def test_scoped_unicode_property_any_sequence_uses_flat_vm
    regexp = Onibi::Regexp.new("(?i:\\p{Letter}.)x")
    program = regexp.send(:bytecode_program)

    refute(program.instructions.any? { |instruction| instruction.opcode == :semantic_match })
    assert_equal ::Regexp.new("(?i:\\p{Letter}.)x").match("ſax")&.to_a,
                 regexp.match("ſax")&.to_a
  end

  def test_scoped_unicode_property_word_boundary_sequence_uses_flat_vm
    regexp = Onibi::Regexp.new("(?i:\\p{Letter}\\b)-")
    program = regexp.send(:bytecode_program)

    refute(program.instructions.any? { |instruction| instruction.opcode == :semantic_match })
    assert_equal ::Regexp.new("(?i:\\p{Letter}\\b)-").match("ſ-")&.to_a,
                 regexp.match("ſ-")&.to_a
  end

  def test_scoped_unicode_property_multiple_ascii_escapes_use_flat_vm
    regexp = Onibi::Regexp.new("(?i:\\p{Letter}\\d\\w)x")
    program = regexp.send(:bytecode_program)

    refute(program.instructions.any? { |instruction| instruction.opcode == :semantic_match })
    assert_equal ::Regexp.new("(?i:\\p{Letter}\\d\\w)x").match("ſ7ax")&.to_a,
                 regexp.match("ſ7ax")&.to_a
  end

  def test_scoped_property_literal_lookahead_sequence_uses_flat_vm
    regexp = Onibi::Regexp.new("(?i:(?=a)\\p{Letter})x")
    program = regexp.send(:bytecode_program)

    refute(program.instructions.any? { |instruction| instruction.opcode == :semantic_match })
    assert_equal ::Regexp.new("(?i:(?=a)\\p{Letter})x").match("ax")&.to_a,
                 regexp.match("ax")&.to_a
  end

  def test_scoped_property_literal_negative_lookahead_uses_flat_vm
    regexp = Onibi::Regexp.new("(?i:(?!a)\\p{Letter})x")
    program = regexp.send(:bytecode_program)

    refute(program.instructions.any? { |instruction| instruction.opcode == :semantic_match })
    assert_equal ::Regexp.new("(?i:(?!a)\\p{Letter})x").match("bx")&.to_a,
                 regexp.match("bx")&.to_a
  end

  def test_scoped_property_literal_lookbehind_sequence_uses_flat_vm
    regexp = Onibi::Regexp.new("(?i:(?<=a)\\p{Letter})x")
    program = regexp.send(:bytecode_program)

    refute(program.instructions.any? { |instruction| instruction.opcode == :semantic_match })
    assert_equal ::Regexp.new("(?i:(?<=a)\\p{Letter})x").match("aſx")&.to_a,
                 regexp.match("aſx")&.to_a
  end

  def test_scoped_property_trailing_literal_lookahead_uses_flat_vm
    regexp = Onibi::Regexp.new("(?i:\\p{Letter}(?=x))x")
    program = regexp.send(:bytecode_program)

    refute(program.instructions.any? { |instruction| instruction.opcode == :semantic_match })
    assert_equal ::Regexp.new("(?i:\\p{Letter}(?=x))x").match("ſx")&.to_a,
                 regexp.match("ſx")&.to_a
  end

  def test_scoped_property_any_lookahead_sequence_uses_flat_vm
    regexp = Onibi::Regexp.new("(?i:(?=.)\\p{Letter})x")
    program = regexp.send(:bytecode_program)

    refute(program.instructions.any? { |instruction| instruction.opcode == :semantic_match })
    assert_equal ::Regexp.new("(?i:(?=.)\\p{Letter})x").match("ſx")&.to_a,
                 regexp.match("ſx")&.to_a
  end

  def test_scoped_property_lookahead_escape_sequence_uses_flat_vm
    regexp = Onibi::Regexp.new("(?i:(?=a)\\p{Letter}\\d)x")
    program = regexp.send(:bytecode_program)

    refute(program.instructions.any? { |instruction| instruction.opcode == :semantic_match })
    assert_equal ::Regexp.new("(?i:(?=a)\\p{Letter}\\d)x").match("a7x")&.to_a,
                 regexp.match("a7x")&.to_a
  end

  def test_scoped_property_literal_negative_lookbehind_sequence_uses_flat_vm
    regexp = Onibi::Regexp.new("(?i:(?<!a)\\p{Letter})x")
    program = regexp.send(:bytecode_program)

    refute(program.instructions.any? { |instruction| instruction.opcode == :semantic_match })
    assert_equal ::Regexp.new("(?i:(?<!a)\\p{Letter})x").match("cbx")&.to_a,
                 regexp.match("cbx")&.to_a
  end

  def test_scoped_ascii_capture_backreference_uses_flat_vm
    regexp = Onibi::Regexp.new("(?i:(a)\\1)")
    program = regexp.send(:bytecode_program)

    refute(program.instructions.any? { |instruction| instruction.opcode == :semantic_match })
    assert_equal ::Regexp.new("(?i:(a)\\1)").match("aA")&.to_a,
                 regexp.match("aA")&.to_a
  end

  def test_scoped_ascii_named_capture_backreference_uses_flat_vm
    regexp = Onibi::Regexp.new("(?i:(?<value>a)\\k<value>)")
    program = regexp.send(:bytecode_program)

    refute(program.instructions.any? { |instruction| instruction.opcode == :semantic_match })
    assert_equal ::Regexp.new("(?i:(?<value>a)\\k<value>)").match("aA")&.to_a,
                 regexp.match("aA")&.to_a
  end

  def test_scoped_ascii_capture_conditional_uses_flat_vm
    regexp = Onibi::Regexp.new("(?i:(a)(?(1)b|c))")
    program = regexp.send(:bytecode_program)

    refute(program.instructions.any? { |instruction| instruction.opcode == :semantic_match })
    assert_equal ::Regexp.new("(?i:(a)(?(1)b|c))").match("ab")&.to_a,
                 regexp.match("ab")&.to_a
  end

  def test_scoped_optional_capture_conditional_uses_flat_vm
    regexp = Onibi::Regexp.new("(?i:(a)?(?(1)b|c))")
    program = regexp.send(:bytecode_program)

    refute(program.instructions.any? { |instruction| instruction.opcode == :semantic_match })
    assert_equal ::Regexp.new("(?i:(a)?(?(1)b|c))").match("ac")&.to_a,
                 regexp.match("ac")&.to_a
    assert_equal ::Regexp.new("(?i:(a)?(?(1)b|c))").match("ab")&.to_a,
                 regexp.match("ab")&.to_a
  end

  def test_scoped_capture_conditional_property_branch_uses_flat_vm
    regexp = Onibi::Regexp.new("(?i:(a)?(?(1)\\p{Letter}|c))")
    program = regexp.send(:bytecode_program)

    refute(program.instructions.any? { |instruction| instruction.opcode == :semantic_match })
    assert_equal ::Regexp.new("(?i:(a)?(?(1)\\p{Letter}|c))").match("aſ")&.to_a,
                 regexp.match("aſ")&.to_a
    assert_equal ::Regexp.new("(?i:(a)?(?(1)\\p{Letter}|c))").match("c")&.to_a,
                 regexp.match("c")&.to_a
  end

  def test_scoped_capture_conditional_property_escape_branches_use_flat_vm
    regexp = Onibi::Regexp.new("(?i:(a)?(?(1)\\p{Letter}|\\d))")
    program = regexp.send(:bytecode_program)

    refute(program.instructions.any? { |instruction| instruction.opcode == :semantic_match })
    assert_equal ::Regexp.new("(?i:(a)?(?(1)\\p{Letter}|\\d))").match("aſ")&.to_a,
                 regexp.match("aſ")&.to_a
    assert_equal ::Regexp.new("(?i:(a)?(?(1)\\p{Letter}|\\d))").match("7")&.to_a,
                 regexp.match("7")&.to_a
  end

  def test_scoped_capture_conditional_alternation_branch_uses_flat_vm
    regexp = Onibi::Regexp.new("(?i:(a)?(?(1)(?:\\p{Letter}|a)|\\d))")
    program = regexp.send(:bytecode_program)

    refute(program.instructions.any? { |instruction| instruction.opcode == :semantic_match })
    assert_equal ::Regexp.new("(?i:(a)?(?(1)(?:\\p{Letter}|a)|\\d))").match("aſ")&.to_a,
                 regexp.match("aſ")&.to_a
    assert_equal ::Regexp.new("(?i:(a)?(?(1)(?:\\p{Letter}|a)|\\d))").match("7")&.to_a,
                 regexp.match("7")&.to_a
  end

  def test_scoped_capture_conditional_sequence_branch_uses_flat_vm
    regexp = Onibi::Regexp.new("(?i:(a)?(?(1)\\p{Letter}\\d|c))")
    program = regexp.send(:bytecode_program)

    refute(program.instructions.any? { |instruction| instruction.opcode == :semantic_match })
    assert_equal ::Regexp.new("(?i:(a)?(?(1)\\p{Letter}\\d|c))").match("aſ7")&.to_a,
                 regexp.match("aſ7")&.to_a
    assert_equal ::Regexp.new("(?i:(a)?(?(1)\\p{Letter}\\d|c))").match("c")&.to_a,
                 regexp.match("c")&.to_a
  end

  def test_scoped_literal_absence_uses_flat_vm
    regexp = Onibi::Regexp.new("(?i:(?~a))b")
    program = regexp.send(:bytecode_program)

    refute(program.instructions.any? { |instruction| instruction.opcode == :semantic_match })
    assert_equal ::Regexp.new("(?i:(?~a))b").match("xb")&.to_a,
                 regexp.match("xb")&.to_a
  end

  def test_scoped_property_absence_uses_flat_vm
    regexp = Onibi::Regexp.new("(?i:(?~\\p{Letter}))b")
    program = regexp.send(:bytecode_program)

    refute(program.instructions.any? { |instruction| instruction.opcode == :semantic_match })
    assert_equal ::Regexp.new("(?i:(?~\\p{Letter}))b").match("1b")&.to_a,
                 regexp.match("1b")&.to_a
  end

  def test_scoped_literal_alternation_absence_uses_flat_vm
    regexp = Onibi::Regexp.new("(?i:(?~(?:a|b)))c")
    program = regexp.send(:bytecode_program)

    refute(program.instructions.any? { |instruction| instruction.opcode == :semantic_match })
    assert_equal ::Regexp.new("(?i:(?~(?:a|b)))c").match("xc")&.to_a,
                 regexp.match("xc")&.to_a
  end

  def test_leading_absolute_start_lookahead_uses_flat_vm
    regexp = Onibi::Regexp.new("(?=\\A)a")
    program = regexp.send(:bytecode_program)

    refute(program.instructions.any? { |instruction| instruction.opcode == :semantic_match })
    assert_equal ::Regexp.new("(?=\\A)a").match("a")&.to_a,
                 regexp.match("a")&.to_a
    assert_nil regexp.match("ba")
  end

  def test_leading_absolute_start_negative_lookahead_uses_flat_vm
    regexp = Onibi::Regexp.new("(?!\\A)b")
    program = regexp.send(:bytecode_program)

    refute(program.instructions.any? { |instruction| instruction.opcode == :semantic_match })
    assert_equal ::Regexp.new("(?!\\A)b").match("ab")&.to_a,
                 regexp.match("ab")&.to_a
  end

  def test_terminal_end_assertions_use_flat_vm
    ["(?=\\z)", "(?!\\z)"].each do |source|
      regexp = Onibi::Regexp.new(source)
      program = regexp.send(:bytecode_program)

      refute(program.instructions.any? { |instruction| instruction.opcode == :semantic_match })
      ["", "a", "ab"].each do |input|
        assert_equal ::Regexp.new(source).match(input)&.to_a,
                     regexp.match(input)&.to_a
      end
    end
  end

  def test_terminal_before_final_newline_assertions_use_flat_vm
    ["(?=\\Z)", "(?!\\Z)"].each do |source|
      regexp = Onibi::Regexp.new(source)
      program = regexp.send(:bytecode_program)

      refute(program.instructions.any? { |instruction| instruction.opcode == :semantic_match })
      ["", "a", "a\n", "ab\n"].each do |input|
        assert_equal ::Regexp.new(source).match(input)&.to_a,
                     regexp.match(input)&.to_a
      end
    end
  end

  def test_scoped_simple_unicode_casefold_uses_flat_vm
    regexp = Onibi::Regexp.new("(?i:ſ)")
    program = regexp.send(:bytecode_program)

    refute(program.instructions.any? { |instruction| instruction.opcode == :semantic_match })
    ["s", "S", "ſ"].each do |input|
      assert_equal ::Regexp.new("(?i:ſ)").match(input)&.to_a,
                   regexp.match(input)&.to_a
    end
  end

  def test_anchored_scoped_simple_unicode_casefold_uses_flat_vm
    ["\\A(?i:ſ)"].each do |source|
      regexp = Onibi::Regexp.new(source)
      program = regexp.send(:bytecode_program)

      refute(program.instructions.any? { |instruction| instruction.opcode == :semantic_match })
      ["s", "S", "ſ", "xs", "sx"].each do |input|
        assert_equal ::Regexp.new(source).match(input)&.to_a,
                     regexp.match(input)&.to_a
      end
    end
  end

  def test_fixed_scoped_simple_unicode_casefold_uses_flat_vm
    regexp = Onibi::Regexp.new("(?i:ſ){1}")
    program = regexp.send(:bytecode_program)

    refute(program.instructions.any? { |instruction| instruction.opcode == :semantic_match })
    ["s", "S", "ſ"].each do |input|
      assert_equal ::Regexp.new("(?i:ſ){1}").match(input)&.to_a,
                   regexp.match(input)&.to_a
    end
  end

  def test_scoped_simple_unicode_casefold_lookahead_uses_flat_vm
    ["(?i:(?=ſ))", "(?i:(?!ſ))"].each do |source|
      regexp = Onibi::Regexp.new(source)
      program = regexp.send(:bytecode_program)

      refute(program.instructions.any? { |instruction| instruction.opcode == :semantic_match })
      ["", "s", "S", "ſ", "xs"].each do |input|
        assert_equal ::Regexp.new(source).match(input)&.to_a,
                     regexp.match(input)&.to_a
      end
    end
  end

  def test_scoped_unicode_fold_alternation_with_suffix_keeps_compatibility
    regexp = Onibi::Regexp.new("(?i:(?:ſ|a))b")
    program = regexp.send(:bytecode_program)

    refute(program.instructions.any? { |instruction| instruction.opcode == :semantic_match })
    ["ſb", "ab", "sb", "ſc"].each do |input|
      assert_equal ::Regexp.new("(?i:(?:ſ|a))b").match(input)&.to_a,
                   regexp.match(input)&.to_a
    end
  end

  def test_scoped_reverse_unicode_literal_suffix_uses_flat_vm
    regexp = Onibi::Regexp.new("(?i:ſ)b")
    program = regexp.send(:bytecode_program)

    refute(program.instructions.any? { |instruction| instruction.opcode == :semantic_match })
    ["ſb", "sb", "ſc", "xb"].each do |input|
      assert_equal ::Regexp.new("(?i:ſ)b").match(input)&.to_a,
                   regexp.match(input)&.to_a
    end
  end

  def test_negated_class_repeat_scoped_suffix_uses_flat_vm
    regexp = Onibi::Regexp.new("[^a]+(?i:a)")
    program = regexp.send(:bytecode_program)

    refute(program.instructions.any? { |instruction| instruction.opcode == :semantic_match })
    ["ba", "bxa", "bA", "a"].each do |input|
      assert_equal ::Regexp.new("[^a]+(?i:a)").match(input)&.to_a,
                   regexp.match(input)&.to_a
    end
  end

  def test_nullable_repeat_negative_assertion_uses_flat_vm
    regexp = Onibi::Regexp.new("ς?(?!ß){1}")
    program = regexp.send(:bytecode_program)

    refute(program.instructions.any? { |instruction| instruction.opcode == :semantic_match })
    ["", "ς", "σ", "ß", "ss", "ςß", "ßς"].each do |input|
      expected = ::Regexp.new("ς?(?!ß){1}").match(input)
      assert_equal [expected&.to_a, expected&.offset(0)],
                   [regexp.match(input)&.to_a, regexp.match(input)&.offset(0)]
    end
  end

  def test_fixed_scoped_unicode_fold_alternation_matches_mri_boundaries
    regexp = Onibi::Regexp.new("(?i:(?:ſ|a)){1}b")
    expected = ::Regexp.new("(?i:(?:ſ|a)){1}b").match("ſb")

    refute(regexp.send(:bytecode_program).instructions.any? { |instruction| instruction.opcode == :semantic_match })
    assert_equal [expected&.to_a, expected&.offset(0)],
                 [regexp.match("ſb")&.to_a, regexp.match("ſb")&.offset(0)]
  end

  def test_fixed_scoped_non_reverse_unicode_fold_with_suffix_uses_flat_vm
    regexp = Onibi::Regexp.new("(?i:Ω){1}b")
    program = regexp.send(:bytecode_program)

    refute(program.instructions.any? { |instruction| instruction.opcode == :semantic_match })
    ["Ωb", "ωb"].each do |input|
      assert_equal ::Regexp.new("(?i:Ω){1}b").match(input)&.to_a,
                   regexp.match(input)&.to_a
    end
  end

  def test_scoped_non_reverse_unicode_fold_assertions_use_flat_vm
    ["(?i:(?=Ω))", "(?i:(?!Ω))", "(?i:(?<=Ω))", "(?i:(?<!Ω))"].each do |source|
      regexp = Onibi::Regexp.new(source)
      program = regexp.send(:bytecode_program)

      refute(program.instructions.any? { |instruction| instruction.opcode == :semantic_match })
      ["", "Ω", "ω", "xω"].each do |input|
        assert_equal ::Regexp.new(source).match(input)&.to_a,
                     regexp.match(input)&.to_a
      end
    end
  end

  def test_scoped_non_reverse_unicode_fold_sequence_uses_flat_vm
    ["(?i:Ωa)", "(?i:Ωa)b"].each do |source|
      regexp = Onibi::Regexp.new(source)
      program = regexp.send(:bytecode_program)

      refute(program.instructions.any? { |instruction| instruction.opcode == :semantic_match })
      ["Ωa", "ωa", "Ωab", "ωab"].each do |input|
        assert_equal ::Regexp.new(source).match(input)&.to_a,
                     regexp.match(input)&.to_a
      end
    end
  end

  def test_scoped_non_reverse_unicode_fold_optional_uses_flat_vm
    regexp = Onibi::Regexp.new("(?i:Ω?)")
    program = regexp.send(:bytecode_program)

    refute(program.instructions.any? { |instruction| instruction.opcode == :semantic_match })
    ["", "Ω", "ω", "b", "Ωb", "ωb"].each do |input|
      assert_equal ::Regexp.new("(?i:Ω?)").match(input)&.to_a,
                   regexp.match(input)&.to_a
    end
  end

  def test_scoped_non_reverse_unicode_fold_optional_with_suffix_keeps_compatibility
    regexp = Onibi::Regexp.new("(?i:Ω?)b")
    program = regexp.send(:bytecode_program)

    refute(program.instructions.any? { |instruction| instruction.opcode == :semantic_match })
    ["Ωb", "ωb", "b", "xΩb"].each do |input|
      assert_equal ::Regexp.new("(?i:Ω?)b").match(input)&.to_a,
                   regexp.match(input)&.to_a
    end
  end

  def test_scoped_non_reverse_unicode_fold_fixed_repeat_uses_flat_vm
    regexp = Onibi::Regexp.new("(?i:Ω{2})")
    program = regexp.send(:bytecode_program)

    refute(program.instructions.any? { |instruction| instruction.opcode == :semantic_match })
    ["ΩΩ", "Ωω", "ωω"].each do |input|
      assert_equal ::Regexp.new("(?i:Ω{2})").match(input)&.to_a,
                   regexp.match(input)&.to_a
    end
  end

  def test_scoped_non_reverse_unicode_fold_bounded_repeat_uses_flat_vm
    regexp = Onibi::Regexp.new("(?i:Ω{1,2})")
    program = regexp.send(:bytecode_program)

    refute(program.instructions.any? { |instruction| instruction.opcode == :semantic_match })
    ["Ω", "ω", "ΩΩ", "ωω", "Ωω"].each do |input|
      assert_equal ::Regexp.new("(?i:Ω{1,2})").match(input)&.to_a,
                   regexp.match(input)&.to_a
    end
  end

  def test_scoped_unicode_fold_bounded_repeat_with_suffix_uses_flat_vm
    regexp = Onibi::Regexp.new("(?i:Ω{1,2})b")
    program = regexp.send(:bytecode_program)

    refute(program.instructions.any? { |instruction| instruction.opcode == :semantic_match })
    ["Ωb", "ωb", "ΩΩb", "Ωωb", "b"].each do |input|
      assert_equal ::Regexp.new("(?i:Ω{1,2})b").match(input)&.to_a,
                   regexp.match(input)&.to_a
    end
  end

  def test_scoped_non_reverse_unicode_fold_unbounded_positive_repeat_uses_flat_vm
    regexp = Onibi::Regexp.new("(?i:Ω+)")
    program = regexp.send(:bytecode_program)

    refute(program.instructions.any? { |instruction| instruction.opcode == :semantic_match })
    ["Ω", "ω", "ΩΩ", "ωω", "Ωω"].each do |input|
      assert_equal ::Regexp.new("(?i:Ω+)").match(input)&.to_a,
                   regexp.match(input)&.to_a
    end
  end

  def test_scoped_non_reverse_unicode_fold_unbounded_optional_repeat_uses_flat_vm
    regexp = Onibi::Regexp.new("(?i:Ω*)")
    program = regexp.send(:bytecode_program)

    refute(program.instructions.any? { |instruction| instruction.opcode == :semantic_match })
    ["", "Ω", "ω", "ΩΩ", "ωω", "xΩ"].each do |input|
      assert_equal ::Regexp.new("(?i:Ω*)").match(input)&.to_a,
                   regexp.match(input)&.to_a
    end
  end

  def test_scoped_non_reverse_unicode_fold_alternation_repeat_uses_flat_vm
    regexp = Onibi::Regexp.new("(?i:(?:Ω|a)+)")
    program = regexp.send(:bytecode_program)

    refute(program.instructions.any? { |instruction| instruction.opcode == :semantic_match })
    ["Ω", "ω", "a", "Ωa", "aω"].each do |input|
      assert_equal ::Regexp.new("(?i:(?:Ω|a)+)").match(input)&.to_a,
                   regexp.match(input)&.to_a
    end
  end

  def test_scoped_unicode_backreference_preserves_source_fold_boundary
    regexp = Onibi::Regexp.new("(?i:(?<x>Ω)\\k<x>)")

    refute(regexp.send(:bytecode_program).instructions.any? do |instruction|
      instruction.opcode == :semantic_match
    end)

    assert_equal ::Regexp.new("(?i:(?<x>Ω)\\k<x>)").match("Ωω")&.to_a,
                 regexp.match("Ωω")&.to_a
    assert_equal ::Regexp.new("(?i:(?<x>Ω)\\k<x>)").match("ΩΩ")&.to_a,
                 regexp.match("ΩΩ")&.to_a
  end

  def test_scoped_unicode_alternation_backreference_lowers_to_flat_bytecode
    regexp = Onibi::Regexp.new("(?i:(?<x>Ω|a)\\k<x>)")
    refute regexp.send(:bytecode_program).instructions.any? { |instruction| instruction.opcode == :semantic_match }

    ["ΩΩ", "Ωω", "aa", "aA", "aΩ"].each do |input|
      assert_equal ::Regexp.new("(?i:(?<x>Ω|a)\\k<x>)").match(input)&.to_a,
                   regexp.match(input)&.to_a
    end
  end

  def test_scoped_unicode_nested_alternation_backreference_lowers_to_flat_bytecode
    regexp = Onibi::Regexp.new("(?i:(?<x>(?:Ω|a))\\k<x>)")
    refute regexp.send(:bytecode_program).instructions.any? { |instruction| instruction.opcode == :semantic_match }

    ["ΩΩ", "Ωω", "aa", "aA", "aΩ"].each do |input|
      assert_equal ::Regexp.new("(?i:(?<x>(?:Ω|a))\\k<x>)").match(input)&.to_a,
                   regexp.match(input)&.to_a
    end
  end

  def test_scoped_unicode_deeply_nested_backreference_lowers_to_flat_bytecode
    regexp = Onibi::Regexp.new("(?i:(?<x>(?:(?:Ω|a)))\\k<x>)")
    refute regexp.send(:bytecode_program).instructions.any? { |instruction| instruction.opcode == :semantic_match }

    ["ΩΩ", "Ωω", "aa", "aA", "aΩ"].each do |input|
      assert_equal ::Regexp.new("(?i:(?<x>(?:(?:Ω|a)))\\k<x>)").match(input)&.to_a,
                   regexp.match(input)&.to_a
    end
  end

  def test_noencoding_byte_escape_uses_flat_vm
    regexp = Onibi::Regexp.new("\\xFF", Onibi::Regexp::NOENCODING)
    program = regexp.send(:bytecode_program)

    refute(program.instructions.any? { |instruction| instruction.opcode == :semantic_match })
    assert(program.instructions.any? { |instruction| instruction.opcode == :semantic_flat })
    assert regexp.match?("\xFF".b)
    refute regexp.match?("a".b)
  end

  def test_casefold_class_candidates_still_require_class_membership
    expected = ::Regexp.new("[a-z]", ::Regexp::IGNORECASE).match?("-".b)
    actual = Onibi::Regexp.new("[a-z]", Onibi::Regexp::IGNORECASE).match?("-".b)

    assert_equal expected, actual
  end

  def test_binary_linebreak_escape_does_not_treat_nel_as_unicode_linebreak
    input = [0x85].pack("C*").b
    expected = ::Regexp.new("\\R").match?(input)
    actual = Onibi::Regexp.new("\\R").match?(input)

    assert_equal expected, actual
  end

  def test_binary_space_escape_uses_binary_whitespace_table
    input = [0x85].pack("C*").b
    expected = ::Regexp.new("\\S").match?(input)
    actual = Onibi::Regexp.new("\\S").match?(input)

    assert_equal expected, actual
  end

  def test_exact_bounded_nullable_repeat_keeps_last_nonempty_capture
    regexp = Onibi::Regexp.new("(a?){2}")
    expected = ::Regexp.new("(a?){2}").match("aa")
    actual = regexp.match("aa")

    assert_equal expected.to_a, actual.to_a
    assert_equal expected.offset(1), actual.offset(1)
    refute regexp.send(:bytecode_program).instructions.any? { |instruction| instruction.opcode == :semantic_match }
  end

  def test_lazy_inner_nullable_repeat_keeps_ordered_zero_width_choice
    ["(a??)?", "(a??)*", "(a??)+", "(a??){2,3}"].each do |pattern|
      expected = ::Regexp.new(pattern).match("a")
      actual = Onibi::Regexp.new(pattern).match("a")

      assert_equal expected.to_a, actual.to_a, pattern
      assert_equal expected.offset(0), actual.offset(0), pattern
    end
  end

  private

  def semantic_node?(value)
    return value.all? { |item| semantic_node?(item) } if value.is_a?(Array)
    return true unless value.respond_to?(:each_pair)

    refute value.class.name.start_with?("Onibi::AST::")
    value.each_pair.all? { |_field, child| semantic_node?(child) }
  end

  def dfa_program_for(source)
    cfg = Onibi::Compiler.compile(Onibi::Parser.parse(source)).graph
    dfa = Onibi::Automata::DFA.from_tnfa(Onibi::Automata::GlushkovTNFA.from_cfg(cfg))
    Onibi::IRGen::YARVIR.generate(dfa)
  end

  def nfa_program_for(source)
    cfg = Onibi::Compiler.compile(Onibi::Parser.parse(source)).graph
    tnfa = Onibi::Automata::GlushkovTNFA.from_cfg(cfg)
    Onibi::IRGen::YARVIR.generate(tnfa, mode: :nfa)
  end
end
