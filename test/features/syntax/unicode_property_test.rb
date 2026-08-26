# frozen_string_literal: true

require "test_helper"

class UnicodePropertyTest < Minitest::Test
  def test_property_polarity_is_composed_once
    ["\\p{^L}", "\\P{^L}"].each do |source|
      expected = ::Regexp.new(source).match("a")&.to_a
      actual = Onibi::Regexp.new(source).match("a")&.to_a

      assert_equal expected, actual, source
    end
  end

  def test_ascii_and_han_properties
    assert Onibi::Regexp.new("\\p{ASCII}").match?("A")
    refute Onibi::Regexp.new("\\p{ASCII}").match?("é")
    assert Onibi::Regexp.new("\\p{Han}").match?("漢")
    refute Onibi::Regexp.new("\\p{Han}").match?("A")
  end

  def test_case_properties
    assert Onibi::Regexp.new("\\p{Lower}").match?("é")
    refute Onibi::Regexp.new("\\p{Lower}").match?("É")
  end

  def test_uncased_unicode_scripts_are_alpha_and_word
    assert Onibi::Regexp.new("\\p{Alpha}").match?("あ")
    assert Onibi::Regexp.new("\\p{Word}").match?("あ")
    assert Onibi::Regexp.new("[[:word:]]").match?("あ")
  end

  def test_uncased_letters_are_not_upper_or_lower_and_ascii_posix_class_matches
    refute Onibi::Regexp.new("\\p{Upper}").match?("あ")
    refute Onibi::Regexp.new("\\p{Lower}").match?("あ")
    assert Onibi::Regexp.new("[[:ascii:]]").match?("A")
    refute Onibi::Regexp.new("[[:ascii:]]").match?("あ")
  end

  def test_negated_property_and_posix_digit_class
    assert Onibi::Regexp.new("\\P{ASCII}").match?("é")
    refute Onibi::Regexp.new("\\P{ASCII}").match?("A")
    assert Onibi::Regexp.new("[[:digit:]]+").match?("42")
    refute Onibi::Regexp.new("[[:digit:]]+").match?("ab")
  end

  def test_invalid_unicode_property_raises_regexp_error
    assert_raises(Onibi::RegexpError) { Onibi::Regexp.new("\\p{NotAProperty}") }
  end
end
