# frozen_string_literal: true

require_relative "../../test_helper"

class SearchPlanTest < Minitest::Test
  def test_absolute_start_is_anchored_and_does_not_scan_later_positions
    regexp = Onibi::Regexp.new("\\Aneedle")
    plan = regexp.send(:codegen_program).search_plan

    assert plan.anchor_start
    assert_equal :anchored, plan.search_mode
    assert_equal [0], plan.candidate_positions("xneedle", 0)
    assert_empty plan.candidate_positions("xneedle", 1)
  end

  def test_minimum_width_limits_candidates
    regexp = Onibi::Regexp.new("needle")
    plan = regexp.send(:codegen_program).search_plan

    assert_equal 6, plan.minimum_width
    assert_equal [2], plan.candidate_positions("xxneedle", 0)
    assert_empty plan.candidate_positions("xxne", 0)
  end

  def test_required_literal_candidates_preserve_leftmost_order
    regexp = Onibi::Regexp.new("needle.*")
    plan = regexp.send(:codegen_program).search_plan

    assert_equal "needle", plan.required_literal
    assert_equal [2, 9], plan.candidate_positions("xxneedle-needle", 0)
  end

  def test_search_plan_matches_mri_for_explicit_positions
    pattern = "\\Aneedle"
    input = "needle needle"
    regexp = Onibi::Regexp.new(pattern)
    expected = ::Regexp.new(pattern)

    [-1, 0, 1, input.length].each do |position|
      assert_equal expected.match?(input, position), regexp.match?(input, position)
    end
  end
end
