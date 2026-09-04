# frozen_string_literal: true

require "test_helper"

class SemanticStateTest < Minitest::Test
  def setup
    @regexp = Onibi::Regexp.new("a")
  end

  def test_action_success_returns_an_independent_successor
    info = diagnostic(:transaction_success)

    assert info[:success]
    assert_equal 1, info[:predecessor_reported_start]
    assert_equal 1, info[:sibling_reported_start]
    assert_equal 2, info[:successor_reported_start]
    assert_equal(-1, info[:predecessor_capture])
    assert_equal(-1, info[:sibling_capture])
    assert_equal 2, info[:successor_capture]
    assert_equal 7, info[:successor_counter]
    assert_equal 2, info[:successor_progress]
    assert_equal 1, info[:tag_event_count]
  end

  def test_action_failure_discards_all_changes
    info = diagnostic(:transaction_failure)

    refute info[:success]
    assert_equal 1, info[:predecessor_reported_start]
    assert_equal 1, info[:sibling_reported_start]
    assert_equal 1, info[:successor_reported_start]
    assert_equal(-1, info[:predecessor_capture])
    assert_equal(-1, info[:sibling_capture])
    assert_equal(-1, info[:successor_capture])
    assert_equal 0, info[:successor_counter]
    assert_equal(-1, info[:successor_progress])
    assert_equal 0, info[:register_delta_count]
    assert_equal 0, info[:tag_event_count]
  end

  def test_match_reset_is_published_only_from_the_accepted_state
    accepted = diagnostic(:transaction_success)
    rejected = diagnostic(:transaction_failure)

    assert_equal 2, accepted[:published_reported_start]
    assert_equal 1, rejected[:published_reported_start]
  end

  def test_dynamic_key_uses_each_future_observable_state_part
    info = diagnostic(:dynamic_key)

    assert info[:distinguishes].values.all?
    assert info[:hash_distinguishes].values.all?
    assert info[:equal_values_equal]
    assert info[:equal_values_hash_equal]
    assert info[:different_delta_histories]
    assert info[:output_history_ignored]
    assert_equal %i[captures counters progress calls atomic absence tag_history],
                 info[:representations]
  end

  def test_branch_updates_store_only_changed_registers
    transaction = diagnostic(:transaction_success)
    scale = diagnostic(:dynamic_key)

    assert_equal 0, transaction[:full_file_copies]
    assert_equal 3, transaction[:register_delta_count]
    assert_operator scale[:register_delta_count], :<, scale[:capture_slot_count]
    assert_operator scale[:register_delta_count], :<, scale[:counter_slot_count]
  end

  def test_key_hash_uses_cached_register_file_hashes
    info = diagnostic(:dynamic_key)

    assert_operator info[:key_hash_count], :>, 0
    assert_equal 0, info[:key_hash_register_reads]
    assert info[:cached_file_hash_changed]
    assert info[:one_slot_key_hash_changed]
    assert_equal 1, info[:one_slot_update_register_reads]
    assert_operator info[:one_slot_update_register_reads], :<,
                    info[:counter_slot_count]
  end

  def test_dedup_hash_set_grows_without_merging_semantic_threads
    info = diagnostic(:dedup_growth)

    assert info[:same_location]
    assert_equal info[:requested], info[:inserted]
    assert_equal info[:requested], info[:key_count]
    assert info[:duplicate_seen]
    assert_operator info[:key_capacity], :>, 64
  end

  def test_dynamic_stack_grows_without_dropping_threads
    info = diagnostic(:dedup_growth)

    assert_equal info[:requested], info[:frame_count]
    assert_operator info[:frame_capacity], :>=, info[:requested]
    assert info[:stack_valid]
  end

  private

  def diagnostic(name)
    @regexp.send(:__onibi_semantic_state_diagnostics__, name)
  end
end
