# frozen_string_literal: true

module Onibi
  # Maps lexer token types to their AST node constructors.
  module ParserTokens
    AST_BUILDERS = {
      literal: ->(token) { AST::Literal.new(token.value) },
      digit: ->(token) { AST::Escape.new(token.type) },
      not_digit: ->(token) { AST::Escape.new(token.type) },
      space: ->(token) { AST::Escape.new(token.type) },
      not_space: ->(token) { AST::Escape.new(token.type) },
      word: ->(token) { AST::Escape.new(token.type) },
      not_word: ->(token) { AST::Escape.new(token.type) },
      horizontal_space: ->(token) { AST::Escape.new(token.type) },
      not_horizontal_space: ->(token) { AST::Escape.new(token.type) },
      linebreak: ->(token) { AST::Escape.new(token.type) },
      word_boundary: ->(token) { AST::Escape.new(token.type) },
      not_word_boundary: ->(token) { AST::Escape.new(token.type) },
      start_match: ->(token) { AST::Escape.new(token.type) },
      match_reset: ->(token) { AST::Escape.new(token.type) },
      grapheme: ->(token) { AST::Escape.new(token.type) },
      property: ->(token) { AST::Property.new(token.value[0], token.value[1]) },
      backreference: ->(token) { AST::Backreference.new(token.value, token.value.is_a?(String)) },
      subexpression_call: ->(token) { AST::SubexpressionCall.new(token.value[0], token.value[1]) },
      class: ->(token) { AST::CharacterClass.new(token.value) },
      dot: ->(token) { AST::Any.new(token.value) },
      anchor_start: ->(token) { AST::Anchor.new(token.type) },
      anchor_end: ->(token) { AST::Anchor.new(token.type) },
      anchor_absolute_start: ->(token) { AST::Anchor.new(token.type) },
      anchor_before_final_newline: ->(token) { AST::Anchor.new(token.type) },
      anchor_absolute_end: ->(token) { AST::Anchor.new(token.type) }
    }.freeze
  end
end
