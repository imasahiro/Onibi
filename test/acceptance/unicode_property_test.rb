# frozen_string_literal: true

require "test_helper"

class UnicodePropertyTest < Minitest::Test
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
