# frozen_string_literal: true

module Onibi
  # Provides opt-in scan and gsub operations for Onibi::Regexp.
  module RegexpScanGsub
    include RegexpReplacement
    UNDEFINED_REPLACEMENT = Object.new.freeze

    def scan(input)
      if block_given?
        scan_results(input) { |result| yield scan_value_from_result(result, input) }
        return input
      end

      values = []
      scan_results(input) { |result| values << scan_value_from_result(result, input) }
      values
    end

    def gsub(input, replacement = UNDEFINED_REPLACEMENT, &block)
      validate_gsub_input!(input)
      replacement = normalize_replacement(replacement, block_given?)
      result, cursor = replace_matches(input, replacement, block)
      result << input.byteslice(cursor, input.bytesize - cursor) if cursor < input.bytesize
      result
    end

    private

    def replace_matches(input, replacement, block)
      return replace_literal_matches(input, replacement) if !block && replacement.index("\\").nil?

      result = String.new(encoding: input.encoding)
      cursor = 0
      each_match(input) do |match|
        result << input.byteslice(cursor, match.begin(0) - cursor)
        result << replacement_for(match, input, replacement, &block)
        cursor = match.end(0)
      end
      [result, cursor]
    end

    def replace_literal_matches(input, replacement)
      result = String.new(encoding: input.encoding)
      cursor = 0
      each_result(input) do |raw|
        result << input.byteslice(cursor, raw[0] - cursor)
        result << replacement
        cursor = raw[1]
      end
      [result, cursor]
    end

    def scan_results(input, &block)
      raise TypeError, "no implicit conversion of #{input.class} into String" unless input.is_a?(String)

      each_result(input, &block)
    end

    def each_result(input, &block)
      return codegen_each_result(input, &block) unless hfa_each_result(input, &block)

      nil
    end

    def each_match(input, &block)
      raise TypeError, "no implicit conversion of #{input.class} into String" unless input.is_a?(String)

      return enum_for(__method__, input) unless block

      return nil if hfa_each_result(input) do |result|
        block.call(hfa_match_data(result, input))
      end

      codegen_each_match(input, &block)
    end

    def scan_value(match)
      match.length == 1 ? match[0] : match.captures
    end

    def scan_value_from_result(result, input)
      captures = result[2]
      return input.byteslice(result[0], result[1] - result[0]) if captures.empty?

      if captures.all? { |capture| capture.nil? || (capture.is_a?(Array) && capture.length == 2) }
        return captures.map do |offset|
          offset && input.byteslice(offset[0], offset[1] - offset[0])
        end
      end

      scan_value(hfa_match_data(result, input))
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
  end
end
