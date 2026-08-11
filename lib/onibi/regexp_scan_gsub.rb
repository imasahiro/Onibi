# frozen_string_literal: true

module Onibi
  # Provides opt-in scan and gsub operations for Onibi::Regexp.
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

    def gsub(input, replacement = UNDEFINED_REPLACEMENT, &block)
      validate_gsub_input!(input)
      replacement = normalize_replacement(replacement, block_given?)
      result = String.new(encoding: input.encoding)
      cursor = 0

      each_match(input) do |match|
        result << input[cursor...match.begin(0)]
        result << replacement_for(match, input, replacement, &block)
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

    def validate_gsub_input!(input)
      return if input.is_a?(String)

      raise TypeError, "no implicit conversion of #{input.class} into String"
    end

    def normalize_replacement(replacement, with_block)
      if replacement.equal?(UNDEFINED_REPLACEMENT)
        raise ArgumentError, "wrong number of arguments (given 1, expected 2)" unless with_block

        return replacement
      end

      replacement = replacement.to_str if replacement.respond_to?(:to_str)
      validate_replacement_type!(replacement) unless with_block
      replacement
    end

    def validate_replacement_type!(replacement)
      return if replacement.is_a?(String)

      raise TypeError, "no implicit conversion of #{replacement.class} into String"
    end

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
