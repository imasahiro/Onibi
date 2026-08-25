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
    ["(?~(a|ab))*", "a"],
    ["a\\Kb", "ab"],
    ["(a)\\1", "aa"]
  ].freeze

  def test_advanced_syntax_corpus_matches_mri
    CASES.each do |pattern, input|
      mri = Regexp.new(pattern).match(input)
      onibi = Onibi::Regexp.new(pattern).match(input)

      assert_equal mri&.to_a, onibi&.to_a, pattern
      assert_equal mri&.offset(0), onibi&.offset(0), pattern
    end
  end

  def test_numeric_subexpression_calls_execute_from_bytecode
    mri = Regexp.new("(a)\\g<1>").match("aa")
    onibi = Onibi::Regexp.new("(a)\\g<1>").match("aa")

    assert_equal mri&.to_a, onibi&.to_a
  end

  def test_undefined_subexpression_calls_fail_during_compilation
    assert_raises(Onibi::RegexpError) { Onibi::Regexp.new("\\g<missing>").match("x") }
  end

  def test_undefined_named_backreferences_fail_during_compilation
    assert_raises(Onibi::RegexpError) { Onibi::Regexp.new("\\k<missing>") }
  end

  def test_undefined_conditional_reference_fails_during_compilation
    assert_raises(Onibi::RegexpError) { Onibi::Regexp.new("(?(1)a|b)") }
    assert_raises(Onibi::RegexpError) { Onibi::Regexp.new("(?(<missing>)a|b)") }
  end

  def test_numeric_subexpression_calls_are_rejected_with_named_captures
    assert_raises(Onibi::RegexpError) { Onibi::Regexp.new("(?<x>a)\\g<1>").match("aa") }
  end
end
