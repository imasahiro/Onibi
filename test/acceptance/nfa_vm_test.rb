# frozen_string_literal: true

require "test_helper"

class NfaVmTest < Minitest::Test
  def test_public_matching_uses_leftmost_search_and_alternation
    ENV["ONIBI_TRACE"] = "1"
    assert Onibi::Regexp.new("cd").match?("xxcdyy")
    regexp = Onibi::Regexp.new("ab|cd")

    assert regexp.match?("xxcdyy"), regexp.instance_variable_get(:@bytecode).instructions.inspect
    refute Onibi::Regexp.new("ab|cd").match?("xxefyy")
  ensure
    ENV.delete("ONIBI_TRACE")
  end

  def test_public_matching_handles_groups_and_greedy_star
    regexp = Onibi::Regexp.new("a(bc)*d")

    assert regexp.match?("abcbcd"), regexp.instance_variable_get(:@bytecode).instructions.inspect
    assert Onibi::Regexp.new("a*").match?("bbb")
  end

  def test_long_non_match_completes_without_recursive_backtracking
    refute Onibi::Regexp.new("a*b").match?("a" * 1_000)
  end
end
