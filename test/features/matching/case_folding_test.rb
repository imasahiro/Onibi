# frozen_string_literal: true

require "test_helper"

class CaseFoldingTest < Minitest::Test
  def test_ignorecase_matches_unicode_simple_case_folding
    assert Onibi::Regexp.new("k", ["ignorecase"]).match?("K")
  end

  def test_ignorecase_matches_unicode_full_case_folding
    assert Onibi::Regexp.new("ß", ["ignorecase"]).match?("SS")
  end

  def test_ignorecase_applies_to_character_classes
    assert Onibi::Regexp.new("[k]", ["ignorecase"]).match?("K")
  end

  def test_ignorecase_applies_to_literal_alternations
    assert Onibi::Regexp.new("a|b", ["ignorecase"]).match?("A")
  end

  def test_ignorecase_applies_to_repeated_literals
    assert Onibi::Regexp.new("a+", ["ignorecase"]).match?("A")
  end
end
