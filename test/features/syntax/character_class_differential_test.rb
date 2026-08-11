# frozen_string_literal: true

require "test_helper"

class CharacterClassDifferentialTest < Minitest::Test
  CASES = [
    ["[a-z[0-9]]", %w[5 g], %w[!]],
    ["[a-w&&[^c-g]z]", %w[a b], %w[c d g z]],
    ["[\\-\\]]", ["-", "]"], %w[a]],
    ["[\\x41]", ["A"], ["a"]],
    ["[\\u{1F600}]", ["😀"], ["a"]]
  ].freeze

  def test_character_class_corpus_matches_mri
    CASES.each do |pattern, matching_inputs, non_matching_inputs|
      matching_inputs.each { |input| assert_same_outcome(pattern, input, true) }
      non_matching_inputs.each { |input| assert_same_outcome(pattern, input, false) }
    end
  end

  private

  def assert_same_outcome(pattern, input, expected)
    mri = Regexp.new(pattern).match?(input)
    onibi = Onibi::Regexp.new(pattern).match?(input)

    assert_equal expected, mri, "MRI outcome for #{pattern.inspect} / #{input.inspect}"
    assert_equal mri, onibi, "Onibi outcome for #{pattern.inspect} / #{input.inspect}"
  end
end
