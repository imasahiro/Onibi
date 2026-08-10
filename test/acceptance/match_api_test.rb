# frozen_string_literal: true

require "test_helper"

class MatchApiTest < Minitest::Test
  def test_match_returns_match_data_with_full_match_and_offset
    match = Onibi::Regexp.new("cat").match("wildcat")

    assert_instance_of Onibi::MatchData, match
    assert_equal "cat", match[0]
    assert_equal 4, match.begin(0)
    assert_equal 7, match.end(0)
  end

  def test_match_returns_nil_and_match_question_mark_returns_boolean
    regexp = Onibi::Regexp.new("cat")

    assert_nil regexp.match("dog")
    assert_equal true, regexp.match?("cat")
    assert_equal false, regexp.match?("dog")
  end
end
