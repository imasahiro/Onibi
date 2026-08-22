# frozen_string_literal: true

require "test_helper"

class V2RegexpApiCompatibilityTest < Minitest::Test
  SIMPLE_CASES = [
    ["cat", "wildcat", "cat"],
    ["[a-z]+", "123 abc XYZ", "abc"],
    ["a|b", "xxbxx", "b"],
    ["a.", "za!", "a!"]
  ].freeze

  def test_simple_match_question_and_match_agree_with_mri
    SIMPLE_CASES.each do |pattern, input, expected|
      onibi = Onibi::Regexp.new(pattern)
      mri = ::Regexp.new(pattern)
      assert_equal mri.match?(input), onibi.match?(input), pattern
      assert_equal expected, onibi.match(input).to_s, pattern
      assert_equal mri.match(input).begin(0), onibi.match(input).begin(0), pattern
    end
  end

  def test_simple_capture_match_data_agrees_with_mri
    pattern = "(?<word>[a-z]+)-(?<number>[0-9]+)"
    input = "id=abc-123"
    onibi = Onibi::Regexp.new(pattern).match(input)
    mri = ::Regexp.new(pattern).match(input)

    assert_equal mri.to_a, onibi.to_a
    assert_equal mri.names, onibi.names
    assert_equal mri.offset(0), onibi.offset(0)
    assert_equal mri.offset(1), onibi.offset(1)
    assert_equal mri.offset(2), onibi.offset(2)
  end

  def test_simple_scan_and_gsub_agree_with_mri
    pattern = "[a-z]+"
    input = "one 22 two"
    onibi = Onibi::Regexp.new(pattern)
    mri = ::Regexp.new(pattern)

    assert_equal input.scan(mri), onibi.scan(input)
    assert_equal input.gsub(mri, "X"), onibi.gsub(input, "X")
  end
end
