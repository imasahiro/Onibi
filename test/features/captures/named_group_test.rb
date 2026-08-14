# frozen_string_literal: true

require "test_helper"

class NamedGroupTest < Minitest::Test
  def test_non_capturing_group_does_not_consume_a_capture_number
    match = Onibi::Regexp.new("(?:ab)(cd)").match("abcd")

    assert_equal ["cd"], match.captures
    assert_equal "cd", match[1]
  end

  def test_named_group_is_available_by_name_and_number
    match = Onibi::Regexp.new("(?<word>cat)").match("a cat")

    assert_equal "cat", match[1]
    assert_equal "cat", match["word"]
    assert_equal "cat", match[:word]
    assert_equal({ "word" => "cat" }, match.named_captures)
    assert_equal ["word"], match.names
    assert_equal ["cat"], match.values_at("word")
  end

  def test_named_repeated_literal_group_preserves_capture_value
    match = Onibi::Regexp.new("(?<word>a+)").match("xxaaa")

    assert_equal "aaa", match["word"]
  end

  def test_named_match_data_formats_full_match_and_names
    match = Onibi::Regexp.new("(?<word>cat)").match("a cat")

    assert_equal "cat", match.to_s
    assert_equal '#<MatchData "cat" word:"cat">', match.inspect
  end
end
