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
    assert_equal({ "word" => "cat" }, match.named_captures)
  end
end
