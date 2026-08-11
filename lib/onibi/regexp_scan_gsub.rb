# frozen_string_literal: true

module Onibi
  module RegexpScanGsub
    UNDEFINED_REPLACEMENT = Object.new.freeze

    def scan(input)
      if block_given?
        each_match(input) { |match| yield scan_value(match) }
        return input
      end

      values = []
      each_match(input) { |match| values << scan_value(match) }
      values
    end

    def gsub(input, replacement = UNDEFINED_REPLACEMENT)
      raise TypeError, "no implicit conversion of #{input.class} into String" unless input.is_a?(String)
      if replacement.equal?(UNDEFINED_REPLACEMENT) && !block_given?
        raise ArgumentError, "wrong number of arguments (given 1, expected 2)"
      end

      replacement = replacement.to_str if replacement.respond_to?(:to_str)
      validate_replacement_type!(replacement) unless block_given? || replacement.equal?(UNDEFINED_REPLACEMENT)
      result = String.new(encoding: input.encoding)
      cursor = 0

      each_match(input) do |match|
        result << input[cursor...match.begin(0)]
        result << replacement_for(match, input, replacement) { yield match[0] } if block_given?
        result << replacement_for(match, input, replacement) unless block_given?
        cursor = match.end(0)
      end
      result << input[cursor..] if cursor < input.length
      result
    end

    private

    def each_match(input)
      raise TypeError, "no implicit conversion of #{input.class} into String" unless input.is_a?(String)

      position = 0
      while position <= input.length
        match = self.match(input, position)
        break unless match

        yield match
        next_position = match.end(0)
        position = next_position == position ? position + 1 : next_position
      end
    end

    def scan_value(match)
      match.length == 1 ? match[0] : match.captures
    end

    def validate_replacement_type!(replacement)
      return if replacement.is_a?(String)

      raise TypeError, "no implicit conversion of #{replacement.class} into String"
    end

    def replacement_for(match, input, replacement)
      return String(yield) if block_given?

      expand_replacement(match, input, replacement)
    end

    def expand_replacement(match, input, replacement)
      result = String.new
      index = 0
      while index < replacement.length
        character = replacement[index]
        unless character == "\\"
          result << character
          index += 1
          next
        end

        token, consumed = replacement_token(replacement, index + 1)
        result << replacement_value(token, match, input)
        index += consumed + 1
      end
      result
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
      return match[0] if token == "0" || token == "&"
      return "\\" if token == "\\"
      return input[0...match.begin(0)] if token == "`"
      return input[match.end(0)..] || "" if token == "'"
      return match.captures.compact.last.to_s if token == "+"
      return match[token[2...-1]] if token.start_with?("k<")

      return match[token.to_i].to_s if token >= "0" && token <= "9"

      "\\#{token}"
    end
  end
end
