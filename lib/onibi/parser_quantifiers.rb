# frozen_string_literal: true

module Onibi
  # Parses quantifier suffixes and bounds.
  module ParserQuantifiers
    private

    def parse_quantifier(atom)
      return atom unless current_token&.type == :quantifier

      value = consume.value
      mode, base = quantifier_mode(value)
      kind, minimum, maximum = quantifier_bounds(base)
      mode = :possessive_bounded if mode == :possessive && kind == :bounded

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
  end
end
