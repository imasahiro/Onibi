# frozen_string_literal: true

require_relative "../../test_helper"

class CompiledClassPredicateTest < Minitest::Test
  def test_compiled_predicate_is_immutable_and_matches_ascii_ranges
    predicate = Onibi::ClassPredicates.compiled("a-z")

    assert predicate.frozen?
    assert predicate.matches?("m")
    refute predicate.matches?("7")
  end

  def test_compiled_predicate_preserves_intersection_and_ignorecase
    intersection = Onibi::ClassPredicates.compiled("a-z&&[^aeiou]")
    folded = Onibi::ClassPredicates.compiled("a", ignorecase: true)

    assert intersection.matches?("b")
    refute intersection.matches?("a")
    assert folded.matches?("A")
  end

  def test_regexp_matching_remains_mri_equivalent
    pattern = "[a-z&&[^aeiou]]+"
    input = "rhythms 123"

    expected = ::Regexp.new(pattern).match(input)
    actual = Onibi::Regexp.new(pattern).match(input)
    assert_equal [expected&.[](0), expected&.offset(0)], [actual&.[](0), actual&.offset(0)]
  end

  def test_generated_class_predicate_returns_cursor_without_candidate_array
    assert_equal 1, Onibi::Codegen::Casefold.class_candidates("a", 0, "a-z", false)
    assert_nil Onibi::Codegen::Casefold.class_candidates("1", 0, "a-z", false)
  end
end
