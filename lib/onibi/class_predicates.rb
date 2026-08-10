# frozen_string_literal: true

module Onibi
  # Evaluates character class source without delegating to another regexp engine.
  module ClassPredicates
    module_function

    def matches?(source, character)
      character = character.chr(source.encoding) if character.is_a?(Integer)
      posix = POSIX_PROPERTIES[source]
      return UnicodeProperties.matches?(posix, character) if posix

      intersection = split_intersection(source)
      return matches?(intersection[0], character) && matches?(intersection[1], character) if intersection

      negated = source.start_with?("^")
      content = negated ? source[1..] : source
      result = union_matches?(content, character)
      negated ? !result : result
    end

    def split_intersection(source)
      depth = 0
      escaped = false
      source.each_char.with_index do |character, index|
        if intersection_marker?(source, character, index, depth, escaped)
          return [source[0...index], source[(index + 2)..]]
        end

        depth, escaped = intersection_state(character, depth, escaped)
      end

      nil
    end

    def union_matches?(source, character)
      index = 0
      while index < source.length
        first, index = atom(source, index)
        return true if range_matches?(source, index, first, character)
        return true if atom_matches?(first, character)

        index = range_end(source, index, first)
      end

      false
    end

    def atom(source, index)
      if source[index] == "["
        ending = nested_end(source, index)
        return [[:nested, source[(index + 1)...ending]], ending + 1]
      end
      return [[:escaped, source[index + 1]], index + 2] if source[index] == "\\"

      [[:literal, source[index]], index + 1]
    end

    def nested_end(source, index)
      depth = 1
      cursor = index + 1
      loop do
        depth, cursor = nested_state(source[cursor], depth, cursor)
        break unless depth.positive?
      end
      cursor - 1
    end

    def intersection_marker?(source, character, index, depth, escaped)
      !escaped && depth.zero? && character == "&" && source[index, 2] == "&&"
    end

    def intersection_state(character, depth, escaped)
      return [depth, false] if escaped
      return [depth, true] if character == "\\"
      return [depth + 1, false] if character == "["
      return [depth - 1, false] if character == "]"

      [depth, false]
    end

    def range_matches?(source, index, first, character)
      return false unless source[index] == "-" && index + 1 < source.length

      last, = atom(source, index + 1)
      literal?(first) && literal?(last) && character.between?(first[1], last[1])
    end

    def range_end(source, index, first)
      return index unless source[index] == "-" && index + 1 < source.length

      _last, after_last = atom(source, index + 1)
      literal?(first) ? after_last : index
    end

    def nested_state(character, depth, cursor)
      return [depth, cursor + 2] if character == "\\"
      return [depth + 1, cursor + 1] if character == "["
      return [depth - 1, cursor + 1] if character == "]"

      [depth, cursor + 1]
    end

    def atom_matches?(atom, character)
      kind, value = atom
      return value == character if kind == :literal
      return matches?(value, character) if kind == :nested

      escaped_matches?(value, character)
    end

    def escaped_matches?(value, character)
      return value == character unless %w[d D s S w W h H].include?(value)

      CharacterPredicates.escape_matches?(escape_kind(value), character)
    end

    def escape_kind(value)
      {
        "d" => :digit, "D" => :not_digit, "s" => :space, "S" => :not_space,
        "w" => :word, "W" => :not_word, "h" => :horizontal_space, "H" => :not_horizontal_space
      }.fetch(value)
    end

    def literal?(atom)
      atom[0] == :literal
    end
  end
end
