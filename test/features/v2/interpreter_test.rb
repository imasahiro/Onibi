# frozen_string_literal: true

require "test_helper"

class InterpreterTest < Minitest::Test
  def test_bytecode_spec_declares_each_instruction_transition
    assert_equal %i[start match jump accept], Onibi::Interpreter::BYTECODE_SPEC.fetch(:dfa).keys
    assert_equal %i[nfa_start nfa_match nfa_accept], Onibi::Interpreter::BYTECODE_SPEC.fetch(:tnfa).keys
    assert_equal %i[match_literal match_class match_escape match_property match_any
                    match_assertion test_anchor match_absence match_group match_quantifier
                    match_atomic_group match_backreference match_conditional
                    match_subexpression_call match_option_group],
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

  def test_bytecode_program_embeds_semantic_operands_without_ast_nodes
    regexp = Onibi::Regexp.new("(?<word>[a-z]+)(?(<word>)!|c)")
    program = regexp.send(:bytecode_program)

    assert program.flags[:semantic_root]
    assert(program.flags[:subexpressions].values.all? { |body| semantic_node?(body) })
    assert semantic_node?(program.flags[:semantic_root])
    assert(program.instructions.all? { |instruction| semantic_node?(instruction.operand) })
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
    body = program.flags[:semantic_root].parts.first.body.parts.first.body
    characters = "aba".chars
    executor.instance_variable_set(:@characters, characters)
    executor.instance_variable_set(:@steps, 0)

    results = executor.send(:node_results, body, characters, 0, {}, program.flags)

    assert_equal([1, 0, 1], results.map { |_length, state| state[:__match_alternative_index] })
  end

  def test_absence_literal_fast_path_preserves_wrapped_capture
    expected = ::Regexp.new("(?~(a))").match("ba")
    actual = Onibi::Regexp.new("(?~(a))").match("ba")

    assert_equal [expected[0], expected.captures, expected.offset(1)],
                 [actual[0], actual.captures, actual.offset(1)]
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
    expected = ::Regexp.new("(a?){2}").match("aa")
    actual = Onibi::Regexp.new("(a?){2}").match("aa")

    assert_equal expected.to_a, actual.to_a
    assert_equal expected.offset(1), actual.offset(1)
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
