# frozen_string_literal: true

require_relative "../../test_helper"

class ParserDelimiterIndexTest < Minitest::Test
  def test_nested_classes_and_adjacent_delimiters_scale_with_one_index_pass
    open_class = "["
    close_class = "]"
    nested = "#{open_class * 32}a#{close_class * 32}"
    adjacent = "[a]" * 128

    assert Onibi::Regexp.new(nested).match?("a")
    assert Onibi::Regexp.new(adjacent).match?("a" * 128)
  end

  def test_nested_groups_and_unmatched_delimiters_keep_parser_errors
    open_class = "["
    open_group = "("
    close_group = ")"
    nested = "#{open_group * 8}a#{close_group * 8}"
    unmatched_group = "#{open_group * 8}a"
    unmatched_class = "#{open_class * 8}a"
    assert Onibi::Regexp.new(nested).match?("a")

    assert_raises(Onibi::RegexpError) { Onibi::Regexp.new(unmatched_group) }
    assert_raises(Onibi::RegexpError) { Onibi::Regexp.new(unmatched_class) }
  end
end
