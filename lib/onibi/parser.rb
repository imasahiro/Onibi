# frozen_string_literal: true

module Onibi
  # Parses lexer tokens with alternation, concatenation, and quantifier precedence.
  class Parser
    include ParserAssertions
    include ParserQuantifiers
    GROUP_OPENINGS = %i[
      open_group open_non_capture open_named_group
      open_positive_lookahead open_negative_lookahead
    ].freeze
    def initialize(source)
      @tokens = Lexer.new(source).tokens
      @index = 0
      @group_number = 0
    end

    def parse
      expression = parse_alternation
      raise RegexpError, "unexpected token" if current_token

      expression
    end

    private

    def parse_alternation
      branches = [parse_sequence]
      branches << parse_sequence while accept(:alternation)
      branches.length == 1 ? branches.first : AST::Alternation.new(branches)
    end

    def parse_sequence
      parts = []
      parts << parse_atom while current_token && !%i[alternation close_group].include?(current_token.type)
      AST::Sequence.new(parts)
    end

    def parse_atom
      token = current_token
      raise RegexpError, "expected expression" unless token

      atom = if GROUP_OPENINGS.include?(token.type)
               parse_group
             else
               parse_simple_atom(token)
             end

      parse_quantifier(atom)
    end

    def parse_simple_atom(token)
      builder = ParserTokens::AST_BUILDERS[token.type]
      raise RegexpError, "unexpected token #{token.type}" unless builder

      consume
      builder.call(token)
    end

    def parse_group
      opening = consume
      return parse_assertion(opening) if opening.type.to_s.include?("lookahead")

      capture = opening.type != :open_non_capture
      @group_number += 1 if capture
      body = parse_alternation
      expect(:close_group)
      number = capture ? @group_number : nil
      name = opening.type == :open_named_group ? opening.value : nil
      AST::Group.new(body, number, capture, name)
    end

    def current_token
      @tokens[@index]
    end

    def consume(expected = nil)
      token = current_token
      expect(expected) if expected && token&.type != expected
      @index += 1
      token
    end

    def accept(type)
      return false unless current_token&.type == type

      @index += 1
      true
    end

    def expect(type)
      return consume if current_token&.type == type

      raise RegexpError, "expected #{type}"
    end
  end
end
