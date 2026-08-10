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
      return group_prefix_token(index) if absence_group_start?(index) || conditional_group_start?(index)

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

    def group_prefix_token(index)
      return [Lexer::Token.new(:open_absence, "?~", index), index + 3] if absence_group_start?(index)

      conditional_token(index)
    end

    def absence_group_start?(index)
      @source[index] == "(" && @source[index + 1] == "?" && @source[index + 2] == "~"
    end

    def conditional_token(index)
      ending = @source.index(")", index + 3)
      condition = @source[(index + 3)...ending] if ending
      raise RegexpError, "invalid conditional group" unless ending && valid_condition?(condition)

      [Lexer::Token.new(:open_conditional, conditional_value(condition), index), ending + 1]
    end

    def valid_condition?(condition)
      return false if condition.nil? || condition.empty?
      return valid_named_condition?(condition) if condition.start_with?("<")

      condition.chars.all? { |character| character >= "0" && character <= "9" }
    end

    def valid_named_condition?(condition)
      condition.end_with?(">") && condition.length > 2
    end

    def conditional_value(condition)
      return [condition[1...-1], true] if condition.start_with?("<")

      [Integer(condition), false]
    end

    def conditional_group_start?(index)
      @source[index] == "(" && @source[index + 1] == "?" && @source[index + 2] == "("
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
