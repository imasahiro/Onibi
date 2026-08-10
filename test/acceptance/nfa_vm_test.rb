# frozen_string_literal: true

require "test_helper"

class NfaVmTest < Minitest::Test
  def test_public_matching_uses_leftmost_search_and_alternation
    assert Onibi::Regexp.new("ab|cd").match?("xxcdyy")
    refute Onibi::Regexp.new("ab|cd").match?("xxefyy")
  end

  def test_public_matching_handles_groups_and_greedy_star
    assert Onibi::Regexp.new("a(bc)*d").match?("abcbcd")
    assert Onibi::Regexp.new("a*").match?("bbb")
  end

  def test_long_non_match_completes_without_recursive_backtracking
    refute Onibi::Regexp.new("a*b").match?("a" * 1_000)
  end
end
