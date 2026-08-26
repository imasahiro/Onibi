# frozen_string_literal: true

module Onibi
  # Parses quantifier suffixes and bounds.
  module ParserQuantifiers
    private

    def parse_quantifier(atom)
      expression = atom
      while current_token&.type == :quantifier
        value = consume.value
        if value == "?" && nested_bounded_possessive?(expression)
          expression.mode = :lazy
          next
        end

        mode, base = quantifier_mode(value)
        kind, minimum, maximum, exact_bound = quantifier_bounds(base)
        if mode == :possessive && kind == :bounded
          bounded = AST::Quantifier.new(expression, kind, minimum, maximum, :greedy, exact_bound)
          expression = AST::Quantifier.new(bounded, :+, 1, nil, :possessive)
        else
          expression = AST::Quantifier.new(expression, kind, minimum, maximum, mode, exact_bound)
        end
      end
      expression
    end

    def nested_bounded_possessive?(expression)
      expression.is_a?(AST::Quantifier) && expression.mode == :possessive &&
        expression.kind == :+ && expression.expression.is_a?(AST::Quantifier) &&
        expression.expression.kind == :bounded
    end

    def quantifier_mode(value)
      return [:lazy, value[0...-1]] if value.end_with?("?") && value.length > 1
      return [:possessive, value[0...-1]] if value.end_with?("+") && value.length > 1

      [:greedy, value]
    end

    def quantifier_bounds(value)
      return simple_quantifier_bounds(value) unless value.start_with?("{")

      bounds = value[1...-1].split(",", -1)
      raise RegexpError, "invalid quantifier" if bounds.empty?

      minimum = bounds.first.empty? ? 0 : Integer(bounds.first)
      maximum = bounded_maximum(bounds, minimum)
      raise RegexpError, "invalid quantifier" if maximum && maximum < minimum

      [:bounded, minimum, maximum, bounds.length == 1 ? true : nil]
    rescue ArgumentError, TypeError
      raise RegexpError, "invalid quantifier"
    end

    def simple_quantifier_bounds(value)
      minimum = { "*" => 0, "+" => 1, "?" => 0 }.fetch(value)
      maximum = { "*" => nil, "+" => nil, "?" => 1 }.fetch(value)

      [value.to_sym, minimum, maximum, nil]
    end

    def bounded_maximum(bounds, minimum)
      return minimum if bounds.length == 1
      return nil if bounds.last.empty?

      Integer(bounds.last)
    end
  end
end
