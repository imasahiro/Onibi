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

  def test_match_exposes_numbered_captures
    match = Onibi::Regexp.new("(ab)(cd)").match("xxabcdyy")

    assert_equal "abcd", match[0]
    assert_equal %w[ab cd], match.captures
    assert_equal "ab", match[1]
    assert_equal "cd", match[2]
  end

  def test_match_exposes_capture_offsets_and_size
    match = Onibi::Regexp.new("(ab)(cd)").match("xxabcdyy")

    assert_equal [2, 6], match.offset(0)
    assert_equal [2, 4], match.offset(1)
    assert_equal [4, 6], match.offset(2)
    assert_equal 3, match.length
    assert_equal 3, match.size
  end

  def test_match_reports_unmatched_and_repeated_captures
    optional = Onibi::Regexp.new("(a)?b").match("b")
    repeated = Onibi::Regexp.new("(ab)+").match("abab")

    assert_nil optional[1]
    assert_nil optional.offset(1)
    assert_equal "ab", repeated[1]
    assert_equal [2, 4], repeated.offset(1)
  end
end
