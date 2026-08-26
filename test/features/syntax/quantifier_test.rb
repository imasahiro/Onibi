# frozen_string_literal: true

require "test_helper"

class QuantifierTest < Minitest::Test
  def test_core_quantifiers_match_empty_and_repeated_input
    assert Onibi::Regexp.new("a?").match?("bbb")
    assert Onibi::Regexp.new("a+").match?("bbbba")
    assert Onibi::Regexp.new("a{2}").match?("caa")
    assert Onibi::Regexp.new("a{2,4}").match?("caaa")
    refute Onibi::Regexp.new("a{2,4}").match?("ca")
  end

  def test_nested_quantifiers_follow_mri_composition
    [".?{0,2}", "a*{2}", "a+{2}", "a{2}{1,2}", "a??{2}"].each do |source|
      expected = ::Regexp.new(source)
      actual = Onibi::Regexp.new(source)
      %w[a aa aaa aaaa].each do |input|
        assert_equal expected.match(input)&.to_a, actual.match(input)&.to_a, "#{source.inspect} #{input.inspect}"
      end
    end
  end
end
