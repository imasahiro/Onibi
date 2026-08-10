# frozen_string_literal: true

module Onibi
  # Correctness fallback for ASTs that cannot complete through bytecode dispatch.
  class AstMatcher
    include AstMatcherDispatch

    def initialize(ast, options = [])
      @ast = ast
      @ignorecase = options.include?("ignorecase")
      @multiline = options.include?("multiline")
    end

    def match?(input)
      !match_span(input).nil?
    end

    def match_span(input)
      characters = input.chars

      (0..characters.length).each do |start|
        finish = match_positions(@ast, characters, start).max
        return [start, finish] if finish
      end

      nil
    end

    private

    def match_positions(node, characters, position)
      matcher = NODE_MATCHERS[node.class]
      return [] unless matcher

      send(matcher, node, characters, position)
    end

    def sequence_positions(parts, characters, position)
      parts.reduce([position]) do |positions, part|
        positions.flat_map { |current| match_positions(part, characters, current) }
      end
    end

    def quantifier_positions(node, characters, position)
      positions = [position]
      maximum = node.maximum || characters.length + 1
      maximum.times do
        next_positions = positions.flat_map { |current| match_positions(node.expression, characters, current) }.uniq
        break if next_positions.empty? || next_positions == positions

        positions.concat(next_positions).uniq!
      end
      positions.select { |current| current >= position + node.minimum }
    end

    def literal_positions(node, characters, position)
      value = node.value.chars

      expected = @ignorecase ? value.map(&:downcase) : value
      actual = characters[position, value.length]
      actual = actual.map(&:downcase) if @ignorecase

      actual == expected ? [position + value.length] : []
    end

    def class_positions(node, characters, position)
      return [] unless position < characters.length
      return [] unless class_matches?(node.value, characters[position])

      [position + 1]
    end

    def class_matches?(source, character)
      negated = source.start_with?("^")
      content = source[(negated ? 1 : 0)..]
      matched = content.include?(character)
      matched ||= content.each_char.each_cons(3).any? do |first, hyphen, last|
        hyphen == "-" && character >= first && character <= last
      end

      negated ? !matched : matched
    end

    def escape_positions(node, characters, position)
      return [] unless position < characters.length
      return [] unless escape_matches?(node.kind, characters[position])

      [position + 1]
    end

    def escape_matches?(kind, character)
      case kind
      when :digit then character >= "0" && character <= "9"
      when :space then character =~ /\s/
      when :word then character =~ /[A-Za-z0-9_]/
      end
    end

    def anchor_positions(node, characters, position)
      at_start = node.kind == :anchor_start && line_start?(characters, position)
      at_end = node.kind == :anchor_end && line_end?(characters, position)

      at_start || at_end ? [position] : []
    end

    def line_start?(characters, position)
      position.zero? || (@multiline && characters[position - 1] == "\n")
    end

    def line_end?(characters, position)
      position == characters.length || (@multiline && characters[position] == "\n")
    end
  end
end
