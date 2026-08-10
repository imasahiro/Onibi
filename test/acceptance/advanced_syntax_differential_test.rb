# frozen_string_literal: true

require "test_helper"

class AdvancedSyntaxDifferentialTest < Minitest::Test
  CASES = [
    ["(?:a)(b)", "ab"],
    ["(?<word>a)\\k<word>", "aa"],
    ["(?=a)a", "a"],
    ["(?<=a)b", "ab"],
    ["(?>a|ab)b", "abb"],
    ["(a)?(?(1)b|c)", "ab"],
    ["(a)?(?(1)b|c)", "c"],
    ["(?<pair>ab)\\g<pair>", "abab"],
    ["(?~real)", "surrealist"],
    ["(?~real)ist", "surrealist"],
    ["a\\Kb", "ab"]
  ].freeze

  def test_advanced_syntax_corpus_matches_mri
    CASES.each do |pattern, input|
      mri = Regexp.new(pattern).match(input)
      onibi = Onibi::Regexp.new(pattern).match(input)

      assert_equal mri&.to_a, onibi&.to_a, pattern
      assert_equal mri&.offset(0), onibi&.offset(0), pattern
    end
  end
end
