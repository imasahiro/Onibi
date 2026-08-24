# frozen_string_literal: true

require "test_helper"

class SyntaxDifferentialContractTest < Minitest::Test
  CAPTURE_CASES = [
    ["alternation capture priority", "(a|aa)", 0, "aa"],
    ["repeated capture priority", "(a*)(a*)", 0, "aaa"],
    ["adjacent greedy captures", "(.*)(.*)", 0, "ab"]
  ].freeze

  LINEBREAK_CASES = ["\r", "\n", "\r\n", "\u0085", "\u2028", "\u2029"].freeze

  SEMANTIC_CASES = [
    ["dot", ".", 0, "\n"],
    ["dot all", ".", ::Regexp::MULTILINE, "\n"],
    ["line anchors", "^cat$", 0, "dog\ncat\nbird"],
    ["absolute end", "\\Acat\\Z", 0, "cat\n"],
    ["word boundary", "\\bcat\\b", 0, "a cat!"],
    ["class intersection", "[a-w&&[^c-g]z]", 0, "d"],
    ["digit shorthand", "\\d+", 0, "123"],
    ["octal escape", "\\101", 0, "A"],
    ["lazy quantifier", "a+?", 0, "aaa"],
    ["possessive quantifier", "a++a", 0, "aaa"],
    ["lookahead", "(?=a)a", 0, "a"],
    ["backreference", "(a)\\1", 0, "aa"],
    ["named backreference", "(?<x>a)\\k<x>", 0, "aa"],
    ["atomic group", "(?>a|ab)b", 0, "ab"],
    ["conditional group", "(a)?(?(1)b|c)", 0, "ac"],
    ["class and anchor bounded repetition", "(?:[ab]|^){2}", 0, "b"],
    ["class and anchor bounded range", "(?:[ab]|^){2,3}", 0, "b"],
    ["absolute anchor bounded range", "(?:a|\\A){2,3}", 0, "ab"]
  ].freeze

  def test_capture_priority_matches_mri_before_and_after_warmup
    CAPTURE_CASES.each do |name, pattern, options, input|
      expected = normalize(::Regexp.new(pattern, options).match(input))
      regexp = Onibi::Regexp.new(pattern, options)

      assert_observation expected, normalize(regexp.match(input)), name
      3.times { regexp.match(input) }
      assert_observation expected, normalize(regexp.match(input)), "warmed #{name}"
    end
  end

  def test_linebreak_shorthand_matches_mri_across_supported_linebreaks
    LINEBREAK_CASES.each do |linebreak|
      expected = normalize(::Regexp.new("\\R").match("x#{linebreak}y"))
      actual = normalize(Onibi::Regexp.new("\\R").match("x#{linebreak}y"))

      assert_equal expected, actual, linebreak.inspect
    end
  end

  def test_syntax_features_match_mri_before_and_after_warmup
    SEMANTIC_CASES.each do |name, pattern, options, input|
      regexp = Onibi::Regexp.new(pattern, options)
      expected = normalize(::Regexp.new(pattern, options).match(input))

      assert_observation expected, normalize(regexp.match(input)), name
      3.times { regexp.match(input) }
      assert_observation expected, normalize(regexp.match(input)), "warmed #{name}"
    end
  end

  private

  def assert_observation(expected, actual, message)
    expected.nil? ? assert_nil(actual, message) : assert_equal(expected, actual, message)
  end

  def normalize(match)
    return nil unless match

    [match[0], match.captures, (0...match.length).map { |index| match.offset(index) }]
  end
end
