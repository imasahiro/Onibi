# frozen_string_literal: true

require "test_helper"

class NativeCaseEqualityTest < Minitest::Test
  def test_native_boolean_results_match_mri_without_mri_match
    cases = [["a", "ba"], ["a", "z"], ["(a)", "ba"], ["(a)", "z"],
             ['(a)\1', "baa"], ['(a)\1', "ba"], ["", ""], ["é", "あé"]]
    expected = cases.map { |pattern, input| ::Regexp.new(pattern) === input }
    regexps = cases.map { |pattern, _| Onibi::Regexp.new(pattern) }
    original = ::Regexp.instance_method(:match)
    ::Regexp.define_method(:match) { |*| raise "MRI match called" }

    cases.each_with_index do |(_, input), index|
      assert_equal expected[index], regexps[index] === input
    end
  ensure
    ::Regexp.define_method(:match, original) if original
  end

  def test_native_success_retains_mri_object_and_miss_clears_it
    regexp = Onibi::Regexp.new("(a)")
    /prior/.match("prior")
    before = $~

    assert_equal true, regexp === "ba"
    assert_same before, $~
    assert_same before, Onibi::Regexp.last_match
    assert_instance_of ::MatchData, $~
    assert_equal false, regexp === "z"
    assert_nil $~
    assert_nil Onibi::Regexp.last_match
  end

  def test_non_string_input_retains_prior_state
    regexp = Onibi::Regexp.new("a")
    /prior/.match("prior")
    before = $~

    [nil, false, true, 1, :a, Object.new].each do |input|
      assert_equal false, regexp === input
      assert_same before, $~
    end
  end

  def test_explicit_fallback_keeps_mri_match_data_and_backreferences
    regexp = Onibi::Regexp.new('(?<letter>\X)')
    mri = ::Regexp.new('(?<letter>\X)')
    expected = mri === "a"
    captures = $~.to_a
    /prior/.match("prior")

    assert_equal expected, regexp === "a"
    assert_instance_of ::MatchData, $~
    assert_equal captures, $~.to_a
    assert_equal "a", $~[:letter]
    assert_same $~, Onibi::Regexp.last_match
    assert_equal false, regexp === ""
    assert_nil $~
    assert_nil Onibi::Regexp.last_match
  end
end
