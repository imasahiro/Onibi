# frozen_string_literal: true

require "test_helper"

class MatchDataIndexTest < Minitest::Test
  def test_match_value_access_coerces_integer_like_indices_and_rejects_unknown_names
    match = Onibi::Regexp.new("(?<animal>cat)").match("cat")

    assert_equal "cat", match[0.9]
    assert_equal ["cat"], match.values_at(0.9)
    assert_raises(IndexError) { match["unknown"] }
    assert_raises(IndexError) { match.values_at("unknown") }
    assert_raises(TypeError) { match[nil] }
  end
end
