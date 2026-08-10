# frozen_string_literal: true

module Onibi
  # Parses lexer tokens with alternation, concatenation, and quantifier precedence.
  class Parser
    AST_BUILDERS = {
      literal: ->(token) { AST::Literal.new(token.value) },
      digit: ->(token) { AST::Escape.new(token.type) },
      space: ->(token) { AST::Escape.new(token.type) },
      word: ->(token) { AST::Escape.new(token.type) },
      class: ->(token) { AST::CharacterClass.new(token.value) },
      dot: ->(token) { AST::Any.new(token.value) },
      anchor_start: ->(token) { AST::Anchor.new(token.type) },
      anchor_end: ->(token) { AST::Anchor.new(token.type) },
      anchor_absolute_start: ->(token) { AST::Anchor.new(token.type) },
      anchor_before_final_newline: ->(token) { AST::Anchor.new(token.type) },
      anchor_absolute_end: ->(token) { AST::Anchor.new(token.type) }
    }.freeze

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

      atom = token.type == :open_group ? parse_group : parse_simple_atom(token)

      parse_quantifier(atom)
    end

    def parse_simple_atom(token)
      builder = AST_BUILDERS[token.type]
      raise RegexpError, "unexpected token #{token.type}" unless builder

      consume
      builder.call(token)
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
