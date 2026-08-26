# frozen_string_literal: true

require_relative "../../test_helper"

class InvocationStateTest < Minitest::Test
  def test_legacy_name_and_interpreter_state_share_one_implementation
    assert_same Onibi::ExecutionState, Onibi::InvocationState
    assert_same Onibi::ExecutionState::Frame, Onibi::Interpreter::ExecutionFrame
  end

  def test_checkpoint_restores_scope_frames_with_invocation_stacks
    state = Onibi::ExecutionState.new(cursor: 2, search_origin: 1, capture_count: 1)
    frame = state.push_frame(
      kind: :group,
      absent_start: 2,
      absent_end: 5,
      probe_position: 2,
      possible_points: [],
      body_checkpoints: [],
      capture_checkpoints: []
    )
    checkpoint = state.checkpoint
    state.cursor = 9
    state.write_capture(0, [2, 9])
    state.calls << :call
    state.repeats << :repeat
    state.cuts << :cut
    state.push_backtrack(:alternative)
    state.push_frame(kind: :repeat)

    state.restore(checkpoint)

    assert_equal 2, state.cursor
    assert_nil state.captures[0]
    assert_empty state.calls
    assert_empty state.repeats
    assert_empty state.cuts
    assert_empty state.backtracks
    assert_same frame, state.current_frame
  end

  def test_scope_frame_exposes_generic_position_aliases
    frame = Onibi::ExecutionState::Frame.new(
      absent_start: 1,
      absent_end: 4,
      probe_position: 2,
      body_checkpoints: []
    )

    frame.scope_start = 3
    frame.scope_end = 6
    frame.position = 5
    frame.checkpoints = [[5, []]]

    assert_equal [3, 6, 5, [[5, []]]],
                 [frame.scope_start, frame.scope_end, frame.position, frame.checkpoints]
  end

  def test_interpreter_releases_nested_scope_frames_after_matching
    regexp = Onibi::Regexp.new("(a)+")
    executor = Onibi::Interpreter::Executor.new(regexp.send(:bytecode_program))

    assert_equal [0, 2], executor.match("aa")
    assert_empty executor.instance_variable_get(:@state).frames
  end

  def test_checkpoint_restores_cursor_captures_and_activation_arenas
    state = Onibi::InvocationState.new(cursor: 2, search_origin: 1, capture_count: 1)
    checkpoint = state.checkpoint
    state.cursor = 9
    state.write_capture(0, [2, 9])
    state.calls << :call
    state.repeats << :repeat
    state.cuts << :cut

    state.restore(checkpoint)

    assert_equal [2, nil, [], [], [], 1], [state.cursor, state.captures[0], state.calls,
                                           state.repeats, state.cuts, state.search_origin]
  end

  def test_backtrack_checkpoint_is_invocation_local
    state = Onibi::InvocationState.new
    state.push_backtrack(:alternative)

    assert_equal :alternative, state.backtracks.first.first
    refute_same state.backtracks, Onibi::InvocationState.new.backtracks
  end
end
