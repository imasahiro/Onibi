# frozen_string_literal: true

module Onibi
  # Expands Ruby-compatible replacement string tokens for gsub.
  module RegexpReplacement
    private

    def replacement_for(match, input, replacement, &block)
      return String(block.call(match[0])) if block

      expand_replacement(match, input, replacement)
    end

    def expand_replacement(match, input, replacement)
      result = String.new
      index = 0
      while index < replacement.length
        piece, consumed = replacement_piece(replacement, index, match, input)
        result << piece
        index += consumed
      end
      result
    end

    def replacement_piece(replacement, index, match, input)
      return [replacement[index], 1] unless replacement[index] == "\\"

      token, consumed = replacement_token(replacement, index + 1)
      [replacement_value(token, match, input), consumed + 1]
    end

    def replacement_token(replacement, index)
      return ["\\", 1] if index >= replacement.length
      return [replacement[index], 1] unless replacement[index] == "k"

      closing = index + 1
      closing += 1 while closing < replacement.length && replacement[closing] != ">"
      return ["k", 1] if closing == replacement.length

      [replacement[index..closing], closing - index + 1]
    end

    def replacement_value(token, match, input)
      case token
      when "0", "&" then match[0]
      when "\\" then "\\"
      when "`" then input[0...match.begin(0)]
      when "'" then input[match.end(0)..] || ""
      when "+" then match.captures.compact.last.to_s
      else named_or_numbered_replacement(token, match)
      end
    end

    def named_or_numbered_replacement(token, match)
      return match[token[2...-1]] if token.start_with?("k<")
      return match[token.to_i].to_s if ("0".."9").include?(token)

      "\\#{token}"
    end
  end
end
