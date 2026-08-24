# frozen_string_literal: true

require "test_helper"

class AbsenceOperatorTest < Minitest::Test
  def test_absence_operator_stops_before_the_forbidden_match
    match = Onibi::Regexp.new("(?~real)").match("surrealist")

    assert_equal "surrea", match[0]
  end

  def test_absence_operator_can_be_followed_by_a_suffix
    match = Onibi::Regexp.new("(?~real)ist").match("surrealist")

    assert_equal "ealist", match[0]
  end

  def test_absence_operator_evaluates_bytecode_body_alternatives
    regexp = Onibi::Regexp.new("(?~a|b)")

    assert_equal "", regexp.match("a")[0]
    assert_equal "x", regexp.match("xaby")[0]
    assert_equal "cd", regexp.match("cd")[0]
  end

  def test_absence_operator_preserves_body_captures
    match = Onibi::Regexp.new("(?~(a|b))").match("xaby")

    assert_equal "x", match[0]
    assert_equal "a", match[1]
  end

  def test_absence_operator_preserves_captures_from_a_failed_suffix
    pattern = "(?~(?:(a|b)a))"

    %w[a ab b abc].each do |input|
      expected = ::Regexp.new(pattern).match(input)
      actual = Onibi::Regexp.new(pattern).match(input)
      assert_equal expected.to_a, actual.to_a, input
      assert_equal expected.offset(0), actual.offset(0), input
    end
  end

  def test_absence_operator_matches_mri_for_unbounded_greedy_body
    regexp = Onibi::Regexp.new("(?~a+)")

    actual = %w[a aa aaa aaaa aaaaa].map do |input|
      regexp.match(input)[0]
    end
    assert_equal ["", "a", "a", "aa", "aa"], actual
  end

  def test_absence_operator_scans_for_a_greedy_body_match
    regexp = Onibi::Regexp.new("(?~a+)")

    assert_equal "b", regexp.match("ba")[0]
    assert_equal "x", regexp.match("xaby")[0]
  end

  def test_absence_operator_backtracks_to_a_suffix
    match = Onibi::Regexp.new("(?~a+)b").match("ab")

    assert_equal "b", match[0]
    assert_equal [1, 2], match.offset(0)
  end

  def test_absence_operator_retries_after_a_zero_width_star_body
    match = Onibi::Regexp.new("(?~a*)").match("b")

    assert_equal "", match[0]
    assert_equal [1, 1], match.offset(0)
  end

  def test_absence_operator_handles_zero_width_body_positions
    ["(?~^)", "(?~\\b)", "(?~(?=a))"].each do |pattern|
      expected = ::Regexp.new(pattern).match("ab")
      actual = Onibi::Regexp.new(pattern).match("ab")

      assert_equal expected.to_a, actual.to_a, pattern
      assert_equal expected.offset(0), actual.offset(0), pattern
    end
  end

  def test_absence_operator_keeps_captures_from_a_zero_width_body
    pattern = "(?~(?:(?!a)(a?)))"
    expected = ::Regexp.new(pattern).match("ab")
    actual = Onibi::Regexp.new(pattern).match("ab")

    assert_equal expected.to_a, actual.to_a
    assert_equal expected.offset(0), actual.offset(0)
    assert_equal expected.offset(1), actual.offset(1)
  end

  def test_absence_operator_keeps_capture_from_a_positive_lookahead_boundary
    pattern = "(?~(?:(a?)(?=a)))"

    %w[ab abb abc].each do |input|
      expected = ::Regexp.new(pattern).match(input)
      actual = Onibi::Regexp.new(pattern).match(input)

      assert_equal expected.to_a, actual.to_a, input
      assert_equal expected.offset(0), actual.offset(0), input
    end
  end

  def test_absence_operator_clears_empty_capture_at_input_end
    pattern = "(?~(?:(?!a)(a?)))"
    expected = ::Regexp.new(pattern).match("a")
    actual = Onibi::Regexp.new(pattern).match("a")

    assert_equal expected.to_a, actual.to_a
    assert_equal expected.offset(0), actual.offset(0)
  end

  def test_absence_operator_clears_nullable_captures_on_suffix_failure_at_end
    ["(?~(?:(a?)a))", "(?~(?:(a?)(a|b)))"].each do |pattern|
      expected = ::Regexp.new(pattern).match("")
      actual = Onibi::Regexp.new(pattern).match("")
      assert_equal expected.to_a, actual.to_a, pattern
      assert_equal expected.offset(0), actual.offset(0), pattern
    end
  end

  def test_absence_operator_applies_quantifier_boundary_to_suffix_bodies
    cases = [
      ["(?~(?:a*(a|b)))", %w[aa aab ab aaaab aaab]],
      ["(?~(?:a*[ab]))", %w[aa aab ab aaaab]],
      ["(?~(?:a*.))", %w[aa aab ab aaaab]]
    ]

    cases.each do |pattern, inputs|
      inputs.each do |input|
        expected = ::Regexp.new(pattern).match(input)
        actual = Onibi::Regexp.new(pattern).match(input)
        assert_equal expected.to_a, actual.to_a, [pattern, input]
        assert_equal expected.offset(0), actual.offset(0), [pattern, input]
      end
    end
  end

  def test_absence_operator_preserves_repeated_atom_boundary
    pattern = "(?~(?:a+a))"
    %w[aaaab aaaa baaaa].each do |input|
      expected = ::Regexp.new(pattern).match(input)
      actual = Onibi::Regexp.new(pattern).match(input)

      assert_equal expected.to_a, actual.to_a
      assert_equal expected.offset(0), actual.offset(0)
    end
  end

  def test_absence_operator_preserves_quantified_suffix_boundary
    [
      ["(?~(?:a+.))", "aaaab"],
      ["(?~(?:[ab]+[ab]))", "aaaab"],
      ["(?~(?:[ab]+a))", "aaaab"],
      ["(?~(?:[ab]+a))", "aaa"],
      ["(?~(?:a+aa))", "aaaab"],
      ["(?~(?:a+a+))", "aaaab"],
      ["(?~(?:a+a*))", "aaab"]
    ].each do |pattern, input|
      expected = ::Regexp.new(pattern).match(input)
      actual = Onibi::Regexp.new(pattern).match(input)

      assert_equal expected.to_a, actual.to_a, pattern
      assert_equal expected.offset(0), actual.offset(0), pattern
    end
  end

  def test_absence_operator_discards_capture_from_failed_quantified_suffix
    pattern = "(?~(?:a+(a|b)))"
    %w[aab aaaa].each do |input|
      expected = ::Regexp.new(pattern).match(input)
      actual = Onibi::Regexp.new(pattern).match(input)

      assert_equal expected.to_a, actual.to_a
      assert_equal expected.offset(0), actual.offset(0)
    end
  end

  def test_absence_operator_uses_fixed_star_suffix_width
    [
      ["(?~(?:a*aa))", "aaa"],
      ["(?~(?:a*aa))", "aaab"],
      ["(?~(?:a*aaa))", "aaaa"]
    ].each do |pattern, input|
      expected = ::Regexp.new(pattern).match(input)
      actual = Onibi::Regexp.new(pattern).match(input)

      assert_equal expected.to_a, actual.to_a, pattern
      assert_equal expected.offset(0), actual.offset(0), pattern
    end
  end

  def test_absence_operator_uses_star_wildcard_boundary
    %w[aaab aaaab].each do |input|
      pattern = "(?~(?:a*.))"
      expected = ::Regexp.new(pattern).match(input)
      actual = Onibi::Regexp.new(pattern).match(input)

      assert_equal expected.to_a, actual.to_a
      assert_equal expected.offset(0), actual.offset(0)
    end
  end

  def test_absence_operator_uses_same_wildcard_quantifier_boundary
    %w[aab aaab aaaab abab].each do |input|
      pattern = "(?~(?:.*.))"
      expected = ::Regexp.new(pattern).match(input)
      actual = Onibi::Regexp.new(pattern).match(input)

      assert_equal expected.to_a, actual.to_a
      assert_equal expected.offset(0), actual.offset(0)
    end
  end

  def test_absence_operator_uses_fixed_width_wildcard_suffix_boundary
    {
      "(?~(?:.*[ab]))" => %w[aaa aaaa aaaaa aaac aaca abca aca acb],
      "(?~(?:.*aa))" => %w[aaa aaaa aaaaa],
      "(?~(?:.*(a|b)))" => %w[aaa aaaa aaaaa aaac aaca abca aca acb],
      "(?~(?:.*a+))" => %w[aaa baa aaaa aaab aaba baaa]
    }.each do |pattern, inputs|
      inputs.each do |input|
        expected = ::Regexp.new(pattern).match(input)
        actual = Onibi::Regexp.new(pattern).match(input)

        assert_equal expected.to_a, actual.to_a
        assert_equal expected.offset(0), actual.offset(0)
      end
    end
  end

  def test_absence_operator_replays_variable_suffix_backtracking
    pattern = "(?~(?:.*(ab|a)))"
    inputs = %w[aba aab aabaa abba xxaba xaba xxxaba xxxxaba]

    inputs.each do |input|
      expected = ::Regexp.new(pattern).match(input)
      actual = Onibi::Regexp.new(pattern).match(input)

      assert_equal expected.to_a, actual.to_a, input
      assert_equal expected.offset(0), actual.offset(0), input
    end
  end

  def test_absence_operator_replays_finite_and_positive_quantifier_probes
    cases = [
      ["(?~(?:a?(ab|a)))", %w[aab aaba baab]],
      ["(?~(?:b+(ab|a)))", %w[bab baab]],
      ["(?~(?:b*(a|aa)))", %w[ba baa bbaa bbba bbbaa]]
    ]

    cases.each do |pattern, inputs|
      inputs.each do |input|
        expected = ::Regexp.new(pattern).match(input)
        actual = Onibi::Regexp.new(pattern).match(input)

        assert_equal expected.to_a, actual.to_a, [pattern, input]
        assert_equal expected.offset(0), actual.offset(0), [pattern, input]
      end
    end
  end

  def test_absence_operator_restores_repeated_suffix_capture_frames
    {
      "(?~(?:a+(a|aa)))" => %w[aaa aab aaba baa bbaa baab],
      "(?~(?:a+(ab|a)))" => %w[aaa aaba baab],
      "(?~(?:b+(ab|a)))" => %w[bab baab bbaa]
    }.each do |pattern, inputs|
      inputs.each do |input|
        expected = ::Regexp.new(pattern).match(input)
        actual = Onibi::Regexp.new(pattern).match(input)

        assert_equal expected.to_a, actual.to_a, [pattern, input]
        assert_equal expected.offset(0), actual.offset(0), [pattern, input]
      end
    end
  end

  def test_absence_operator_uses_consuming_width_for_nullable_suffix
    ["(?~(?:.*a?))", "(?~(?:.*a*))"].each do |pattern|
      %w[aaa abac abba aabaa ac].each do |input|
        expected = ::Regexp.new(pattern).match(input)
        actual = Onibi::Regexp.new(pattern).match(input)

        assert_equal expected.to_a, actual.to_a, [pattern, input]
        assert_equal expected.offset(0), actual.offset(0), [pattern, input]
      end
    end
  end

  def test_absence_operator_retries_after_a_nested_zero_width_body
    %w[aa ab abc].each do |input|
      pattern = "(?~(?~a))"
      expected = ::Regexp.new(pattern).match(input)
      actual = Onibi::Regexp.new(pattern).match(input)

      assert_equal expected.to_a, actual.to_a, input
      assert_equal expected.offset(0), actual.offset(0), input
    end
  end

  def test_absence_operator_keeps_a_nullable_body_capture
    match = Onibi::Regexp.new("(?~(a?))").match("a")

    assert_equal ["", "a"], match.to_a
    assert_equal [0, 0], match.offset(0)
    assert_equal [0, 1], match.offset(1)
  end

  def test_absence_operator_propagates_nested_bytecode_endpoints
    cases = [
      ["(?~(?~(?=a)))", "ab"],
      ["(?~(?~(?=a)))", "abb"],
      ["(?~(?:b(?~(?=a))))", "ba"]
    ]

    cases.each do |pattern, input|
      expected = ::Regexp.new(pattern).match(input)
      actual = Onibi::Regexp.new(pattern).match(input)
      assert_equal expected.to_a, actual.to_a, input
      assert_equal expected.offset(0), actual.offset(0), input
    end
  end

  def test_absence_operator_handles_overlapping_nested_zero_width_boundaries
    cases = [
      ["(?~(?:a(?~(?=a))))", "aa"],
      ["(?~(?:b(?~(?=a))))", "ba"],
      ["(?~(?:b(?~(?=b))))", "bb"]
    ]

    cases.each do |pattern, input|
      expected = ::Regexp.new(pattern).match(input)
      actual = Onibi::Regexp.new(pattern).match(input)
      assert_equal expected.to_a, actual.to_a, input
      assert_equal expected.offset(0), actual.offset(0), input
    end
  end

  def test_absence_operator_preserves_alternation_branch_order
    cases = [
      ["(?~(?:b|(?~(?=a))))", "abb"],
      ["(?~(?:(?~(?=a))|b))", "abb"]
    ]

    cases.each do |pattern, input|
      expected = ::Regexp.new(pattern).match(input)
      actual = Onibi::Regexp.new(pattern).match(input)
      assert_equal expected.to_a, actual.to_a, input
      assert_equal expected.offset(0), actual.offset(0), input
    end
  end

  def test_absence_operator_accounts_for_suffix_after_nested_zero_width_body
    %w[ab aba abb aab].each do |input|
      pattern = "(?~(?:(?~(?=a))b))"
      expected = ::Regexp.new(pattern).match(input)
      actual = Onibi::Regexp.new(pattern).match(input)
      assert_equal expected.to_a, actual.to_a, input
      assert_equal expected.offset(0), actual.offset(0), input
    end
  end

  def test_absence_operator_handles_unbounded_range_bodies
    regexp = Onibi::Regexp.new("(?~a{2,})")

    assert_equal(%w[aa aaa], %w[aaaa aaaaa].map { |input| regexp.match(input)[0] })
  end

  def test_absence_operator_handles_unbounded_class_ranges
    regexp = Onibi::Regexp.new("(?~[ab]{2,})")

    assert_equal(%w[aa ab], %w[aaaa abab].map { |input| regexp.match(input)[0] })
  end

  def test_absence_operator_handles_unbounded_group_ranges
    regexp = Onibi::Regexp.new("(?~(ab){2,})")

    assert_equal(%w[ab aba ababa], %w[ab abab ababab].map { |input| regexp.match(input)[0] })
  end

  def test_absence_operator_handles_unbounded_alternation_ranges
    regexp = Onibi::Regexp.new("(?~(a|b){2,})")

    assert_equal(%w[ab aba], %w[abab ababab].map { |input| regexp.match(input)[0] })
  end

  def test_absence_operator_handles_variable_alternation_lengths
    regexp = Onibi::Regexp.new("(?~(a|ab){2,})")

    assert_equal(%w[aa ab ab], %w[aaa abab ababa].map { |input| regexp.match(input)[0] })
  end

  def test_absence_operator_does_not_export_quantifier_body_captures
    match = Onibi::Regexp.new("(?~(a|b){2,})").match("xabab")

    assert_equal "xab", match[0]
    assert_nil match[1]
  end

  def test_absence_operator_handles_nested_equal_length_captures
    match = Onibi::Regexp.new("(?~((a|b)){2,})").match("abab")

    assert_equal "ab", match[0]
    assert_nil match[1]
    assert_nil match[2]
  end

  def test_absence_operator_clears_nested_repeat_captures
    match = Onibi::Regexp.new("(?~((ab)+))").match("ab")

    assert_equal "a", match[0]
    assert_equal "ab", match[1]
    assert_nil match[2]
  end

  def test_absence_operator_tracks_odd_nested_repeat_captures
    regexp = Onibi::Regexp.new("(?~((ab)+))")

    odd = regexp.match("ababab")
    even = regexp.match("abab")
    assert_equal "ab", odd[1]
    assert_nil even[1]
  end

  def test_absence_operator_tracks_nested_alternation_captures
    regexp = Onibi::Regexp.new("(?~((a|b)+))")

    assert_equal %w[a b], regexp.match("aba").to_a.first(2)
    assert_equal %w[aba ab], regexp.match("ababab").to_a.first(2)
    assert_equal %w[aa a], regexp.match("aaaaa").to_a.first(2)
    assert_equal %w[aa a], regexp.match("aaaba").to_a.first(2)
  end

  def test_absence_operator_clears_nested_bounded_captures
    match = Onibi::Regexp.new("(?~((a|ab){2,}))").match("abab")

    assert_equal "ab", match[0]
    assert_nil match[1]
    assert_nil match[2]

    match = Onibi::Regexp.new("(?~((a|ab){2,}))").match("aa")

    assert_equal %w[a aa], match.to_a.first(2)
    assert_nil match[2]
  end

  def test_absence_operator_tracks_variable_nested_alternation
    regexp = Onibi::Regexp.new("(?~((ab|a)+))")

    assert_equal %w[ab a], regexp.match("abab").to_a.first(2)
    assert_equal %w[abab], regexp.match("ababab").to_a.first(1)
    assert_equal %w[a a], regexp.match("aaa").to_a.first(2)
    assert_equal %w[aa ab], regexp.match("aaba").to_a.first(2)
  end

  def test_absence_operator_tracks_nullable_nested_repeat_frames
    regexp = Onibi::Regexp.new("(?~((ab|a)*))")

    assert_equal ["a", ""], regexp.match("aba").to_a.first(2)
    assert_equal ["aa", ""], regexp.match("aabaa").to_a.first(2)
  end

  def test_absence_operator_tracks_bounded_variable_alternation
    regexp = Onibi::Regexp.new("(?~((ab|a){2,}))")

    assert_equal %w[aba], regexp.match("abab").to_a.first(1)
    assert_equal %w[abab], regexp.match("ababab").to_a.first(1)
  end

  def test_absence_operator_clears_nullable_nested_captures
    regexp = Onibi::Regexp.new("(?~((a?|b)+))")

    assert_equal ["", nil, nil], regexp.match("").to_a
    assert_equal ["", nil, nil], regexp.match("b").to_a
    assert_equal %w[a a], regexp.match("baaa").to_a.first(2)
  end
end
