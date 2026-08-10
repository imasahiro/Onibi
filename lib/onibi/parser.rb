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

      atom = if %i[open_group open_non_capture open_named_group].include?(token.type)
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
      capture = opening.type != :open_non_capture
      @group_number += 1 if capture
      body = parse_alternation
      expect(:close_group)
      number = capture ? @group_number : nil
      name = opening.type == :open_named_group ? opening.value : nil
      AST::Group.new(body, number, capture, name)
    end

    def parse_quantifier(atom)
      return atom unless current_token&.type == :quantifier

      value = consume.value
      mode, base = quantifier_mode(value)
      kind, minimum, maximum = quantifier_bounds(base)
      raise RegexpError, "possessive bounded quantifier is not supported" if mode == :possessive && kind == :bounded

      AST::Quantifier.new(atom, kind, minimum, maximum, mode)
    end

    def quantifier_mode(value)
      return [:lazy, value[0...-1]] if value.end_with?("?") && value.length > 1
      return [:possessive, value[0...-1]] if value.end_with?("+") && value.length > 1

      [:greedy, value]
    end

    def quantifier_bounds(value)
      return simple_quantifier_bounds(value) unless value.start_with?("{")

      bounds = value[1...-1].split(",", -1)
      minimum = bounds.first.empty? ? 0 : Integer(bounds.first)
      maximum = bounded_maximum(bounds, minimum)
      raise RegexpError, "invalid quantifier" if maximum && maximum < minimum

      [:bounded, minimum, maximum]
    rescue ArgumentError, TypeError
      raise RegexpError, "invalid quantifier"
    end

    def simple_quantifier_bounds(value)
      minimum = { "*" => 0, "+" => 1, "?" => 0 }.fetch(value)
      maximum = { "*" => nil, "+" => nil, "?" => 1 }.fetch(value)

      [value.to_sym, minimum, maximum]
    end

    def bounded_maximum(bounds, minimum)
      return minimum if bounds.length == 1
      return nil if bounds.last.empty?

      Integer(bounds.last)
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
