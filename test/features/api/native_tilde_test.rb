# frozen_string_literal: true

require "test_helper"

class NativeTildeTest < Minitest::Test
  def test_native_positions_match_mri_without_mri_match
    cases = [["a", "ba"], ["a", "z"], ["(a)", "ba"], ["(a)", "z"],
             ['(a)\1', "baa"], ['(a)\1', "ba"], ["", ""], ["é", "あé"]]
    expected = cases.map do |pattern, input|
      $_ = input
      ~::Regexp.new(pattern)
    end
    regexps = cases.map { |pattern, _| Onibi::Regexp.new(pattern) }
    original = ::Regexp.instance_method(:match)
    ::Regexp.define_method(:match) { |*| raise "MRI match called" }

    cases.each_with_index do |(_, input), index|
      $_ = input
      if expected[index].nil?
        assert_nil(~regexps[index])
      else
        assert_equal expected[index], ~regexps[index]
      end
    end
  ensure
    ::Regexp.define_method(:match, original) if original
    $_ = nil
  end

  def test_native_success_retains_mri_object_and_miss_clears_it
    regexp = Onibi::Regexp.new("(é)")
    /prior/.match("prior")
    before = $~
    $_ = "あé"

    assert_equal 1, ~regexp
    assert_same before, $~
    assert_same before, Onibi::Regexp.last_match
    assert_instance_of ::MatchData, $~
    $_ = "z"
    assert_nil(~regexp)
    assert_nil $~
    assert_nil Onibi::Regexp.last_match
  ensure
    $_ = nil
  end

  def test_non_string_input_retains_prior_state
    regexp = Onibi::Regexp.new("a")
    /prior/.match("prior")
    before = $~

    [nil, false, true, 1, :a, Object.new].each do |input|
      $_ = input
      assert_nil(~regexp)
      assert_same before, $~
      assert_same before, Onibi::Regexp.last_match
    end
  ensure
    $_ = nil
  end

  def test_explicit_fallback_keeps_mri_match_data_and_backreferences
    regexp = Onibi::Regexp.new('x(?<letter>\X)')
    mri = ::Regexp.new('x(?<letter>\X)')
    $_ = "あxa"
    expected = ~mri
    captures = $~.to_a
    /prior/.match("prior")

    assert_equal expected, ~regexp
    assert_instance_of ::MatchData, $~
    assert_equal captures, $~.to_a
    assert_equal "a", $~[:letter]
    assert_same $~, Onibi::Regexp.last_match
    $_ = ""
    assert_nil(~regexp)
    assert_nil $~
    assert_nil Onibi::Regexp.last_match
  ensure
    $_ = nil
  end
end
