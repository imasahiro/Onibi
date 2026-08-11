# frozen_string_literal: true

require "test_helper"

class V1MatchDataContractTest < Minitest::Test
  def test_nested_repeated_unmatched_and_multibyte_captures_match_mri
    source = "(?<outer>(?<inner>é))(?<repeat>a)+(?<missing>b)?"
    input = "ééaa"
    expected = ::Regexp.new(source).match(input)
    actual = Onibi::Regexp.new(source).match(input)

    %i[to_a captures names named_captures pre_match post_match].each do |method|
      assert_equal expected.public_send(method), actual.public_send(method)
    end
    expected.length.times { |index| assert_equal expected.offset(index), actual.offset(index) }
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
