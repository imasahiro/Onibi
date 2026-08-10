# frozen_string_literal: true

module Onibi
  # Preprocesses positive scoped extended-mode groups without a regexp dependency.
  module LexerScopedExtended
    module_function

    def normalize(source)
      result = (+"").force_encoding(source.encoding)
      index = 0
      while index < source.length
        unless source[index, 4] == "(?x:"
          result << source[index]
          index += 1
          next
        end

        ending = group_end(source, index)
        raise RegexpError, "unterminated scoped extended group" unless ending

        body = source[(index + 4)...ending]
        result << "(?:" << strip_extended(normalize(body)) << ")"
        index = ending + 1
      end
      result
    end

    def strip_extended(source)
      result = +""
      index = 0
      in_class = false
      while index < source.length
        if !in_class && source[index, 5] == "(?-x:"
          ending = group_end(source, index)
          raise RegexpError, "unterminated scoped extended group" unless ending

          result << source[index..ending]
          index = ending + 1
          next
        end
        character = source[index]
        if character == "\\"
          result << source[index, 2]
          index += 2
        elsif character == "["
          in_class = true
          result << character
          index += 1
        elsif character == "]" && in_class
          in_class = false
          result << character
          index += 1
        elsif !in_class && character == "#"
          index = source.index("\n", index + 1) || source.length
        elsif !in_class && extended_whitespace?(character)
          index += 1
        else
          result << character
          index += 1
        end
      end
      result
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
