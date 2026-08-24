# frozen_string_literal: true

require "test_helper"

class CaseFoldingTest < Minitest::Test
  def test_ignorecase_does_not_match_a_negated_class_member
    regexp = Onibi::Regexp.new("[^a]", Onibi::Regexp::IGNORECASE)

    refute regexp.match?("a")
    refute regexp.match?("A")
    assert regexp.match?("b")
  end

  def test_ignorecase_applies_to_class_ranges
    assert Onibi::Regexp.new("[a-z]", Onibi::Regexp::IGNORECASE).match?("S")
  end

  def test_ignorecase_class_ranges_follow_mri_unicode_fold_boundaries
    regexp = Onibi::Regexp.new("[a-z]", Onibi::Regexp::IGNORECASE)
    negated = Onibi::Regexp.new("[^a-z]", Onibi::Regexp::IGNORECASE)

    refute regexp.match?("İ")
    assert regexp.match?("ſ")
    assert negated.match?("İ")
    refute negated.match?("ſ")
  end

  def test_ignorecase_matches_unicode_simple_case_folding
    assert Onibi::Regexp.new("k", ["ignorecase"]).match?("K")
  end

  def test_ignorecase_matches_unicode_full_case_folding
    assert Onibi::Regexp.new("ß", ["ignorecase"]).match?("SS")
  end

  def test_ignorecase_matches_unicode_ligature_case_folding
    assert Onibi::Regexp.new("ﬃ", ["ignorecase"]).match?("ffi")
    assert Onibi::Regexp.new("ffi", ["ignorecase"]).match?("ﬃ")
  end

  def test_ignorecase_matches_sharp_s_case_pair
    assert Onibi::Regexp.new("ß", ["ignorecase"]).match?("ẞ")
  end

  def test_ignorecase_applies_to_unicode_property_case_classes
    assert Onibi::Regexp.new("\\p{Upper}", ["ignorecase"]).match?("a")
    assert Onibi::Regexp.new("\\p{Lower}", ["ignorecase"]).match?("A")
    refute Onibi::Regexp.new("\\P{Upper}", ["ignorecase"]).match?("a")
    assert Onibi::Regexp.new("[\\P{Upper}]", ["ignorecase"]).match?("A")
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
