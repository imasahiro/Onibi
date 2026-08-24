# frozen_string_literal: true

require "test_helper"

class LexerParserErrorBoundaryTest < Minitest::Test
  INVALID_PATTERNS = [
    "\\",
    "\\x",
    "\\xG1",
    "\\u12",
    "\\u{}",
    "\\377",
    "\\400",
    "\\777",
    "\\p{}",
    "\\M-",
    "\\C-",
    "[",
    "[]",
    "[^]",
    "[z-a]",
    "(?<",
    "(?(",
    "(?#",
    "(?x:",
    "a{2,1}",
    "*a",
    "a)",
    "(a",
    "(?<=a*)",
    "(?<=a(?:b|cd))"
  ].freeze

  def test_invalid_lexer_and_parser_input_raises_regexp_error
    INVALID_PATTERNS.each do |pattern|
      error = assert_raises(Onibi::RegexpError, pattern) { Onibi::Regexp.new(pattern) }

      refute_instance_of NoMethodError, error, pattern
    end
  end

  def test_boundary_quantifiers_are_accepted_or_rejected_consistently
    assert Onibi::Regexp.new("a{0}").match?("")
    assert Onibi::Regexp.new("a{2,}").match?("aaa")
    assert Onibi::Regexp.new("a{,2}").match?("aa")
    assert Onibi::Regexp.new("a{100000}")
    assert_raises(Onibi::RegexpError) { Onibi::Regexp.new("a{100001}").match?("") }
  end

  def test_malformed_repeat_syntax_is_literal_like_mri
    ["a{", "a{}", "a{,}", "a{,x}", "a{x}", "a{2", "a{2,x}"].each do |pattern|
      expected = ::Regexp.new(pattern)
      actual = Onibi::Regexp.new(pattern)

      assert_equal expected.source, actual.source, pattern
      ["a", "a{", "aa", pattern].each do |input|
        assert_equal expected.match?(input), actual.match?(input), [pattern, input]
      end
    end
  end
end
