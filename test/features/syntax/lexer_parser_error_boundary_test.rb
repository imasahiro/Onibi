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
    "(?<",
    "(?(",
    "(?#",
    "(?x:",
    "a{",
    "a{}",
    "a{2,1}",
    "*a",
    "a)",
    "(a",
    "(?<=a*)",
    "(?<!a|bb)"
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
    assert_raises(Onibi::RegexpError) { Onibi::Regexp.new("a{,x}") }
  end
end
