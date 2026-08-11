# frozen_string_literal: true

module Onibi
  # Matches leaf AST nodes while preserving capture state.
  module CaptureMatcherAtoms
    private

    def literal_results(node, characters, position, captures)
      value = node.value
      return literal_case_sensitive_results(value, characters, position, captures) unless @ignorecase

      expected = value.downcase(:fold)
      maximum = [value.length, expected.length].max * 3
      (1..maximum).filter_map do |length|
        actual = characters[position, length]&.join
        [position + length, captures] if actual && actual.downcase(:fold) == expected
      end
    end

    def class_results(node, characters, position, captures)
      return [] unless position < characters.length

      maximum = full_casefold_class?(node.value) ? 3 : 1
      (1..maximum).filter_map do |length|
        candidate = characters[position, length]&.join
        [position + length, captures] if candidate && class_matches?(node.value, candidate)
      end
    end

    def literal_case_sensitive_results(value, characters, position, captures)
      actual = characters[position, value.length]
      actual == value.chars ? [[position + value.length, captures]] : []
    end

    def full_casefold_class?(source)
      source.each_char.any? { |character| character.downcase(:fold).length > 1 }
    end

    def class_matches?(source, character)
      ClassPredicates.matches?(source, character, ignorecase: @ignorecase)
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
