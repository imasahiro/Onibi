# frozen_string_literal: true

require "test_helper"

class LexerTest < Minitest::Test
  def test_core_syntax_is_tokenized_through_the_public_engine
    tokens = Onibi::Lexer.new("a\\d[bc](x|y)*^$").tokens

    assert_equal %i[literal digit class open_group literal alternation literal close_group quantifier anchor_start anchor_end],
                 tokens.map(&:type)
  end

  def test_escaped_metacharacters_are_literal_tokens
    tokens = Onibi::Lexer.new("\\.\\*").tokens

    assert_equal [[:literal, "."], [:literal, "*"]], tokens.map { |token| [token.type, token.value] }
  end

  def test_malformed_escape_raises_public_error
    assert_raises(Onibi::RegexpError) { Onibi::Lexer.new("\\q").tokens }
  end
end
