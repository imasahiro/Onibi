# frozen_string_literal: true

require "test_helper"

class UnicodePropertyDifferentialTest < Minitest::Test
  CASES = [
    ["\\p{Alpha}", %w[A あ], %w[1]],
    ["\\P{Alpha}", %w[1], %w[A あ]],
    ["\\p{^Alpha}", %w[1], %w[A あ]],
    ["\\p{Hiragana}", ["あ"], ["ア"]],
    ["\\p{Katakana}", ["ア"], ["あ"]],
    ["\\p{Han}", ["漢"], ["あ"]],
    ["[[:digit:]]", %w[0 9], %w[a]],
    ["[[:alpha:]]", %w[A z], %w[1]],
    ["[[:ascii:]]", ["A"], ["あ"]],
    ["[[:word:]]", %w[A 0 _], %w[-]]
  ].freeze

  def test_unicode_and_posix_property_corpus_matches_mri
    CASES.each do |pattern, matching_inputs, non_matching_inputs|
      matching_inputs.each { |input| assert_same_outcome(pattern, input, true) }
      non_matching_inputs.each { |input| assert_same_outcome(pattern, input, false) }
    end
  end

  def test_invalid_unicode_property_errors_match_mri
    assert_equal :error, outcome(Regexp, "\\p{NoSuchProperty}", "x")
    assert_equal :error, outcome(Onibi::Regexp, "\\p{NoSuchProperty}", "x")
  end

  private

  def assert_same_outcome(pattern, input, expected)
    mri = outcome(Regexp, pattern, input)
    onibi = outcome(Onibi::Regexp, pattern, input)

    assert_equal expected, mri, "MRI outcome for #{pattern.inspect} / #{input.inspect}"
    assert_equal mri, onibi, "Onibi outcome for #{pattern.inspect} / #{input.inspect}"
  end

  def outcome(regexp_class, pattern, input)
    regexp_class.new(pattern).match?(input) || false
  rescue StandardError
    :error
  end
end
