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

  def test_match_operator_returns_match_beginning_or_nil
    regexp = Onibi::Regexp.new("cat")

    assert_equal 4, regexp =~ "wildcat"
    assert_nil regexp =~ "dog"
  end

  def test_case_operator_returns_boolean
    regexp = Onibi::Regexp.new("cat")

    assert regexp.send("===", "wildcat")
    refute regexp.send("===", "dog")
  end

  def test_unary_match_operator_uses_last_input
    regexp = Onibi::Regexp.new("cat")

    eval('$_ = "wildcat"', TOPLEVEL_BINDING, __FILE__, __LINE__)
    assert_equal 4, ~regexp
  ensure
    eval("$_ = nil", TOPLEVEL_BINDING, __FILE__, __LINE__)
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

  def test_match_values_at_extracts_indices_and_ranges
    match = Onibi::Regexp.new("(ab)(cd)").match("xxabcdyy")

    assert_equal ["abcd", "cd", nil], match.values_at(0, 2, 9)
    assert_equal %w[abcd ab], match.values_at(0..1)
  end

  def test_match_exposes_input_regexp_and_surrounding_text
    regexp = Onibi::Regexp.new("cat")
    input = "wildcatdog"
    match = regexp.match(input)

    assert_same input, match.string
    assert_same regexp, match.regexp
    assert_equal "wild", match.pre_match
    assert_equal "dog", match.post_match
  end

  def test_match_exposes_byte_offsets_and_match_length
    match = Onibi::Regexp.new("é").match("aéz")

    assert_equal 1, match.bytebegin(0)
    assert_equal 3, match.byteend(0)
    assert_equal [1, 3], match.byteoffset(0)
    assert_equal 1, match.match_length(0)
  end

  def test_match_data_has_value_object_semantics
    first = Onibi::Regexp.new("cat").match("wildcat")
    second = Onibi::Regexp.new("cat").match("wildcat")
    different = Onibi::Regexp.new("cat").match("cat")

    assert_equal first, second
    assert first.eql?(second)
    assert_equal first.hash, second.hash
    refute_equal first, different
  end
end
