# frozen_string_literal: true

require "test_helper"

class V1MatchDataContractTest < Minitest::Test
  def test_nested_repeated_unmatched_and_multibyte_captures_match_mri
    source = "(?<outer>(é)(?<inner>é))(?<repeat>a)+(?<missing>b)?"
    input = "ééaa"
    expected = ::Regexp.new(source).match(input)
    actual = Onibi::Regexp.new(source).match(input)

    assert_equal expected.to_a, actual.to_a
    assert_equal expected.captures, actual.captures
    assert_equal expected.names, actual.names
    assert_equal expected.named_captures, actual.named_captures
    assert_equal expected.offset(0), actual.offset(0)
    assert_equal expected.offset(1), actual.offset(1)
    assert_equal expected.offset(2), actual.offset(2)
    assert_equal expected.offset(3), actual.offset(3)
    assert_equal expected.offset(4), actual.offset(4)
    assert_equal expected.pre_match, actual.pre_match
    assert_equal expected.post_match, actual.post_match
  end

  def test_duplicate_named_captures_resolve_like_mri
    expected = /(?<word>a)(?<word>b)?/.match("a")
    actual = Onibi::Regexp.new("(?<word>a)(?<word>b)?").match("a")

    assert_equal expected.to_a, actual.to_a
    assert_equal expected.named_captures, actual.named_captures
    assert_equal expected["word"], actual["word"]
    assert_equal expected.inspect, actual.inspect
  end
end
