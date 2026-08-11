# frozen_string_literal: true

module Onibi
  # Preprocesses positive scoped extended-mode groups without a regexp dependency.
  module LexerScopedExtended
    module_function

    def normalize(source)
      result = (+"").force_encoding(source.encoding)
      index = 0
      while index < source.length
        result << normalized_fragment(source, index)
        index = normalized_fragment_end(source, index)
      end
      result
    end

    def normalized_fragment(source, index)
      return source[index] unless source[index, 4] == "(?x:"

      ending = group_end(source, index)
      raise RegexpError, "unterminated scoped extended group" unless ending

      body = source[(index + 4)...ending]
      +"(?:" << strip_extended(normalize(body)) << ")"
    end

    def normalized_fragment_end(source, index)
      return index + 1 unless source[index, 4] == "(?x:"

      group_end(source, index) + 1
    end

    def strip_extended(source)
      result = +""
      index = 0
      in_class = false
      while index < source.length
        if !in_class && source[index, 5] == "(?-x:"
          index = append_disabled_extended_group(result, source, index)
          next
        end
        character = source[index]
        index, in_class = append_extended_character(result, source, index, in_class, character)
      end
      result
    end

    def append_disabled_extended_group(result, source, index)
      ending = group_end(source, index)
      raise RegexpError, "unterminated scoped extended group" unless ending

      result << source[index..ending]
      ending + 1
    end

    def append_extended_character(result, source, index, in_class, character)
      return escaped_extended_character(result, source, index, in_class) if character == "\\"
      return class_open_character(result, character, index) if character == "["
      return class_close_character(result, character, index) if character == "]" && in_class
      return comment_character(source, index, in_class) if !in_class && character == "#"
      return [index + 1, in_class] if !in_class && extended_whitespace?(character)

      result << character
      [index + 1, in_class]
    end

    def escaped_extended_character(result, source, index, in_class)
      result << source[index, 2]
      [index + 2, in_class]
    end

    def class_open_character(result, character, index)
      result << character
      [index + 1, true]
    end

    def class_close_character(result, character, index)
      result << character
      [index + 1, false]
    end

    def comment_character(source, index, in_class)
      [source.index("\n", index + 1) || source.length, in_class]
    end

    def group_end(source, opening)
      depth = 0
      in_class = false
      index = opening
      while index < source.length
        character = source[index]
        if character == "\\"
          index += 2
          next
        end
        if character == "["
          in_class = true
        elsif character == "]"
          in_class = false
        elsif !in_class && character == "("
          depth += 1
        elsif !in_class && character == ")"
          depth -= 1
          return index if depth.zero?
        end
        index += 1
      end
      nil
    end

    def extended_whitespace?(character)
      [" ", "\t", "\n", "\r", "\f", "\v"].include?(character)
    end
  end
end
