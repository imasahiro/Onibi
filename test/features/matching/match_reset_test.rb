# frozen_string_literal: true

require "test_helper"

class MatchResetTest < Minitest::Test
  def test_match_reset_excludes_the_prefix_from_the_match_span
    match = Onibi::Regexp.new("a\\Kb").match("ab")

    assert_equal "b", match[0]
    assert_equal 1, match.begin(0)
  end
end
