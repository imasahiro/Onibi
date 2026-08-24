# frozen_string_literal: true

require "test_helper"

class LexerTest < Minitest::Test
  def test_core_syntax_is_tokenized_through_the_public_engine
    tokens = Onibi::Lexer.new("a\\d[bc](x|y)*^$").tokens

    expected = %i[
      literal digit class open_group literal alternation literal close_group
      quantifier anchor_start anchor_end
    ]

    assert_equal expected,
                 tokens.map(&:type)
  end

  def test_escaped_metacharacters_are_literal_tokens
    tokens = Onibi::Lexer.new("\\.\\*").tokens

    actual = tokens.map { |token| [token.type, token.value] }

    assert_equal [[:literal, "."], [:literal, "*"]], actual
  end

  def test_unknown_escape_is_a_literal_token
    token = Onibi::Lexer.new("\\q").tokens.first

    assert_equal :literal, token.type
    assert_equal "q", token.value
  end
end
