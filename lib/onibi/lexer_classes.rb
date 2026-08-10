# frozen_string_literal: true

module Onibi
  # Finds the closing delimiter of nested, escaped character classes.
  module LexerClasses
    private

    def class_ending(index)
      depth = 1
      cursor = index + 1
      loop do
        depth, cursor = class_state(@source[cursor], depth, cursor)
        break unless cursor < @source.length && depth.positive?
      end

      depth.zero? ? cursor : nil
    end

    def class_state(character, depth, cursor)
      return [depth, cursor + 2] if character == "\\"
      return [depth + 1, cursor + 1] if character == "["
      return [depth - 1, cursor + 1] if character == "]"

      [depth, cursor + 1]
    end

    def property_token(index)
      escaped = @source[index + 1]
      ending = property_ending(index)
      raise RegexpError, "invalid Unicode property" unless ending

      name = @source[(index + 3)...ending]
      raise RegexpError, "invalid Unicode property" if name.empty?

      negated = escaped == "P" || name.start_with?("^")
      name = name.sub("^", "")
      UnicodeProperties.validate!(name)
      [Lexer::Token.new(:property, [name, negated], index), ending + 1]
    end

    def property_ending(index)
      return unless @source[index + 2] == "{"

      @source.index("}", index + 3)
    end
  end
end
