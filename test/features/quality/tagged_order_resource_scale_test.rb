# frozen_string_literal: true

require "test_helper"

class TaggedOrderResourceScaleTest < Minitest::Test
  def tagged_info(repeat)
    pattern = "((a)?){#{repeat}}"
    Onibi::Regexp.new(pattern).send(:__onibi_diagnostics__, "a" * repeat)
  end

  def test_tagged_retained_order_and_event_data_has_a_linear_bound
    small_repeat = 8
    large_repeat = 64
    small = tagged_info(small_repeat)
    large = tagged_info(large_repeat)

    [[small, small_repeat], [large, large_repeat]].each do |info, repeat|
      assert_equal 1, info[:exec_kind]
      assert_equal 0, info[:dynamic]
      assert_equal 0, info[:dfs]
      assert_equal 0, info[:fallback]

      # These are fixed per-repeat envelopes, not ratios between two sizes.
      assert_operator info.fetch(:order_nodes), :<=, repeat * 48
      assert_operator info.fetch(:capture_events), :<=, repeat * 4
      assert_operator info.fetch(:capture_event_roots), :<=, repeat * 2
      assert_operator info.fetch(:capture_event_owners), :<=, repeat * 2
      assert_operator info.fetch(:materialization_event_visits), :<=, repeat * 2
    end
  end

  def test_shared_event_prefix_is_materialized_once
    info = tagged_info(8)

    assert_operator info[:capture_event_roots], :>,
                    info[:materialization_event_visits]
    assert_operator info[:materialization_event_visits], :<=,
                    info[:capture_events]
  end

  def test_frontier_entries_use_c_state_without_ruby_containers
    source = File.read(File.expand_path("../../../ext/onibi/exec_dynamic.c", __dir__))
    frontier_add = source[/static int\n?onibi_tagged_frontier_add\(.*?\n}\n/m]

    refute_nil frontier_add
    refute_match(/\bVALUE\b/, frontier_add)
    refute_includes frontier_add, "rb_hash_new"
    refute_includes frontier_add, "rb_ary_new"
    refute_includes frontier_add, "rb_hash_dup"
    assert_includes frontier_add, "OnibiSemanticState ordered = *semantic;"
  end
end
