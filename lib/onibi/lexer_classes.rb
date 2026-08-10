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

    def group_token(index)
      return special_group_token(index) if @source[index, 2] == "(?"

      [Lexer::Token.new(:open_group, "(", index), index + 1]
    end

    def special_group_token(index)
      token = {
        "(?:" => :open_non_capture,
        "(?>" => :open_atomic,
        "(?=" => :open_positive_lookahead,
        "(?!" => :open_negative_lookahead
      }[@source[index, 3]]
      return [Lexer::Token.new(token, @source[(index + 2), 1], index), index + 3] if token
      return lookbehind_token(index) if @source[index, 3] == "(?<"

      raise RegexpError, "unknown group extension"
    end

    def lookbehind_token(index)
      return [Lexer::Token.new(:open_positive_lookbehind, "?<=", index), index + 4] if @source[index, 4] == "(?<="
      return [Lexer::Token.new(:open_negative_lookbehind, "?<!", index), index + 4] if @source[index, 4] == "(?<!"

      named_group_token(index)
    end

    def named_group_token(index)
      ending = @source.index(">", index + 3)
      raise RegexpError, "invalid named capture" unless ending

      name = @source[(index + 3)...ending]
      raise RegexpError, "invalid named capture" if name.empty?

      [Lexer::Token.new(:open_named_group, name, index), ending + 1]
    end
  end
end
