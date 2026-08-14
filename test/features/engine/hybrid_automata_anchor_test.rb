# frozen_string_literal: true

require_relative "../../test_helper"

class HybridAutomataAnchorTest < Minitest::Test
  def test_supports_absolute_string_anchors_in_the_hfa_subset
    program = Onibi::HybridAutomata.compile("\\Aabc\\z")
    assert program.match?("abc")
    refute program.match?("xabc")
    refute program.match?("abcx")
    refute program.match?("xabcx")
  end

  def test_repeated_literal_does_not_bypass_start_anchor
    program = Onibi::HybridAutomata.compile("\\Aa++b")

    refute program.match?("xaaaaab")
    assert program.match?("aaaaab")
  end

  def test_anchored_class_run_returns_full_match_result
    program = Onibi::HybridAutomata.compile("\\A[a-z]+\\z")

    assert_equal [0, 6, []], program.match_result("abcxyz")
    assert_nil program.match_result("abc123")
    assert_equal [[0, 6, []]], program.each_match_result("abcxyz").to_a
  end
end
