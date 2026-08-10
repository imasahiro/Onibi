# frozen_string_literal: true

module Onibi
  # Matches leaf AST nodes while preserving capture state.
  module CaptureMatcherAtoms
    private

    def literal_results(node, characters, position, captures)
      value = node.value.chars
      expected = @ignorecase ? value.map(&:downcase) : value
      actual = characters[position, value.length]
      actual = actual.map(&:downcase) if @ignorecase && actual
      actual == expected ? [[position + value.length, captures]] : []
    end

    def class_results(node, characters, position, captures)
      return [] unless position < characters.length && class_matches?(node.value, characters[position])

      [[position + 1, captures]]
    end

    def option_group_results(node, characters, position, captures)
      original = @ignorecase
      @ignorecase = node.ignorecase
      match_results(node.body, characters, position, captures)
    ensure
      @ignorecase = original
    end

    def class_matches?(source, character)
      ClassPredicates.matches?(source, character)
    end

    def escape_results(node, characters, position, captures)
      if node.kind == :match_reset
        @match_reset_position = position
        return [[position, captures]]
      end
      return zero_width_results(node.kind, characters, position, captures) if zero_width_escape?(node.kind)
      return linebreak_results(characters, position, captures) if node.kind == :linebreak
      return [] unless position < characters.length && escape_matches?(node.kind, characters[position])

      [[position + 1, captures]]
    end

    def property_results(node, characters, position, captures)
      return [] unless position < characters.length

      character = characters[position].encode(Encoding::UTF_8)
      matched = UnicodeProperties.matches?(node.name, character) ^ node.negated
      matched ? [[position + 1, captures]] : []
    end

    def backreference_results(node, characters, position, captures)
      index = node.named ? CaptureNameCollector.call(@ast)[node.identifier] : node.identifier
      offset = captures[index && index - 1]
      return [] unless offset

      length = offset[1] - offset[0]
      characters[position, length] == characters[offset[0]...offset[1]] ? [[position + length, captures]] : []
    end

    def assertion_results(node, characters, position, captures)
      matched = assertion_matches?(node, characters, position, captures)
      matched = !matched if %i[negative negative_lookbehind].include?(node.kind)
      matched ? [[position, captures]] : []
    end

    def atomic_group_results(node, characters, position, captures)
      result = match_results(node.body, characters, position, captures).first
      result ? [result] : []
    end

    def assertion_matches?(node, characters, position, captures)
      return !match_results(node.body, characters, position, captures).empty? unless lookbehind?(node)

      (0..position).any? do |start|
        match_results(node.body, characters, start, captures).any? { |finish, _state| finish == position }
      end
    end

    def lookbehind?(node)
      %i[positive_lookbehind negative_lookbehind].include?(node.kind)
    end

    def escape_matches?(kind, character)
      CharacterPredicates.escape_matches?(kind, character)
    end

    def zero_width_escape?(kind)
      %i[word_boundary not_word_boundary start_match].include?(kind)
    end

    def zero_width_results(kind, characters, position, captures)
      matches = CharacterPredicates.word_boundary?(characters, position)
      matches = !matches if kind == :not_word_boundary
      matches = position.zero? if kind == :start_match
      matches ? [[position, captures]] : []
    end

    def any_results(_node, characters, position, captures)
      return [] unless position < characters.length
      return [] if !@multiline && characters[position] == "\n"

      [[position + 1, captures]]
    end

    def anchor_results(node, characters, position, captures)
      at_start = %i[anchor_start anchor_absolute_start].include?(node.kind) &&
                 anchor_start?(node, characters, position)
      at_end = %i[anchor_end anchor_before_final_newline anchor_absolute_end].include?(node.kind) &&
               anchor_end?(node, characters, position)
      at_start || at_end ? [[position, captures]] : []
    end

    def anchor_start?(node, characters, position)
      return position.zero? if node.kind == :anchor_absolute_start

      line_start?(characters, position)
    end

    def anchor_end?(node, characters, position)
      return position == characters.length if node.kind == :anchor_absolute_end
      if node.kind == :anchor_before_final_newline
        return position == characters.length || final_newline?(characters, position)
      end

      line_end?(characters, position)
    end

    def line_start?(characters, position)
      position.zero? || characters[position - 1] == "\n"
    end

    def line_end?(characters, position)
      position == characters.length || characters[position] == "\n"
    end

    def final_newline?(characters, position)
      position == characters.length - 1 && characters[position] == "\n"
    end
  end
end
