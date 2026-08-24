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

  def test_bytecode_spec_defines_absence_as_complement_of_wrapped_body
    absence = Onibi::Interpreter::BYTECODE_SPEC.fetch(:semantic).fetch(:match_absence)

    assert_equal :complement_of_wrapped_body, absence.fetch(:language)
    assert_equal ".* body .*", absence.fetch(:wrapped_language)
    assert_equal :ordered_body_candidates, absence.fetch(:preserves)
    assert_equal :absent_frame, absence.fetch(:local)
    assert_equal :probe_with_bounded_end, absence.fetch(:transition)
    assert_equal :repeat_frame_state, absence.fetch(:capture_checkpoint)
  end

  def test_absent_frame_contains_stack_checkpoint_fields
    frame = Onibi::Interpreter::AbsentFrame.new(
      absent_start: 0,
      absent_end: 3,
      probe_position: 0,
      possible_points: [[0, {}]],
      body_checkpoints: [[0, [[1, {}]]]],
      capture_checkpoints: []
    )

    assert_equal [0, 3, 0, [[0, {}]], [[0, [[1, {}]]]], []], frame.to_a
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
    regexp = Onibi::Regexp.new("(?<word>[a-z]+)(?(1)!|c)")
    program = regexp.send(:bytecode_program)

    assert program.flags[:semantic_root]
    assert(program.flags[:subexpressions].values.all? { |body| semantic_node?(body) })
    assert semantic_node?(program.flags[:semantic_root])
  end

  def test_interpreter_executes_each_semantic_operand_kind
    cases = [
      ["a", "a"], ["[a]", "a"], ["\\d", "7"], ["\\p{Alpha}", "A"],
      [".", "x"], ["(?=a)a", "a"], ["\\Aa", "a"], ["(?~a)", "b"],
      ["(a)", "a"], ["a+", "aa"], ["(?>a)", "a"], ["(a)\\1", "aa"],
      ["(a)?(?(1)b|c)", "ab"], ["(a)\\g1", "aa"], ["(?i:a)", "A"]
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
