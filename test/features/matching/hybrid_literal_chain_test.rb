# frozen_string_literal: true

require "test_helper"

class HybridLiteralChainTest < Minitest::Test
  CASES = [
    ["foo.{0,4}bar", "xxfoo12bar--foo\n\nbar", 0],
    ["foo.{2,4}?bar", "foo12bar--foo1234bar", 0],
    ["foo[a-z]{0,4}bar", "foo12bar--fooxyzbar", 0],
    ["foo.{0,4}bar", "前置fooあbar--foo12bar", 1],
    ["foo.{0,4}bar", "foo12bar--foo34bar", 1]
  ].freeze

  def test_bounded_literal_chain_matches_mri_through_public_apis
    CASES.each do |pattern, input, position|
      expected = Regexp.new(pattern)
      actual = Onibi::Regexp.new(pattern)

      assert_equal expected.match?(input, position), actual.match?(input, position), pattern
      assert_match_equal expected.match(input, position), actual.match(input, position), pattern
    end
  end

  private

  def assert_match_equal(expected, actual, message)
    expected_value = expected && [expected[0], expected.offset(0)]
    actual_value = actual && [actual[0], actual.offset(0)]
    assert_equal expected_value, actual_value, message
  end
end
