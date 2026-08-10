# frozen_string_literal: true

module Onibi
  # Parses lexer tokens with alternation, concatenation, and quantifier precedence.
  class Parser
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

      atom = case token.type
             when :literal then AST::Literal.new(consume.value)
             when :digit, :space, :word then AST::Escape.new(consume.type)
             when :class then AST::CharacterClass.new(consume.value)
             when :dot then AST::Any.new(consume.value)
             when :anchor_start, :anchor_end then AST::Anchor.new(consume.type)
             when :open_group then parse_group
             else raise RegexpError, "unexpected token #{token.type}"
             end

      parse_quantifier(atom)
    end

    def parse_group
      consume(:open_group)
      @group_number += 1
      body = parse_alternation
      expect(:close_group)
      AST::Group.new(body, @group_number)
    end

    def parse_quantifier(atom)
      return atom unless current_token&.type == :quantifier

      value = consume.value
      kind, minimum, maximum = quantifier_bounds(value)
      AST::Quantifier.new(atom, kind, minimum, maximum)
    end

    def quantifier_bounds(value)
      return [value.to_sym, { "*" => 0, "+" => 1, "?" => 0 }.fetch(value), { "*" => nil, "+" => nil, "?" => 1 }.fetch(value)] unless value.start_with?("{")

      bounds = value[1...-1].split(",", -1)
      minimum = Integer(bounds.first)
      maximum = bounds.length == 1 ? minimum : (bounds.last.empty? ? nil : Integer(bounds.last))
      raise RegexpError, "invalid quantifier" if maximum && maximum < minimum

      [:bounded, minimum, maximum]
    rescue ArgumentError
      raise RegexpError, "invalid quantifier"
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
