# frozen_string_literal: true

require_relative "../../test_helper"

class InvocationStateTest < Minitest::Test
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
