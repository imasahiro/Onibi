# frozen_string_literal: true

module Onibi
  # Provides opt-in scan and gsub operations for Onibi::Regexp.
  module RegexpScanGsub
    include RegexpReplacement
    UNDEFINED_REPLACEMENT = Object.new.freeze

    def scan(input, &block)
      if input.is_a?(String) && input.ascii_only? && hfa_capture_count == 1 &&
         (spec = hfa_alternation_capture_scan_spec)
        values = []
        hfa_alternation_capture_each_scan_value(input, spec) do |value|
          if block
            block.call(value)
          else
            values << value
          end
        end
        return input if block

        return values
      end

      if input.is_a?(String) && input.ascii_only? && hfa_capture_count == 1 &&
         (spec = hfa_literal_prefix_capture_scan_spec)
        values = []
        hfa_literal_prefix_capture_each_scan_value(input, spec) do |value|
          if block
            block.call(value)
          else
            values << value
          end
        end
        return input if block

        return values
      end

      if input.is_a?(String) && input.ascii_only? && hfa_capture_count.positive? &&
         (spec = hfa_capture_sequence_scan_spec)
        values = []
        hfa_capture_sequence_each_scan_value(input, spec) do |value|
          if block
            block.call(value)
          else
            values << value
          end
        end
        return input if block

        return values
      end

      if input.is_a?(String) && input.ascii_only? && hfa_capture_count == 1 &&
         (spec = hfa_direct_delimited_capture_spec)
        values = []
        hfa_direct_delimited_capture_each_match(input, spec) do |start_position, finish_position|
          values << [input.byteslice(start_position, finish_position - start_position)]
        end
        return values unless block

        values.each(&block)
        return input
      end

      if block
        scan_results(input) { |result| block.call(scan_value_from_result(result, input)) }
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

    def hfa_ascii_word_byte?(byte)
      (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) ||
        (byte >= 48 && byte <= 57) || byte == 95
    end

    def hfa_alternation_capture_each_scan_value(input, spec)
      _capture_number, branches = spec
      position = 0
      while position < input.bytesize
        start = nil
        branches.each do |branch|
          candidate = input.index(branch.first, position)
          start = candidate if candidate && (start.nil? || candidate < start)
        end
        break unless start

        finish = hfa_alternation_capture_match_result(input, start, branches)
        if finish
          yield [input.byteslice(start, finish - start)]
          position = finish
        else
          position = start + 1
        end
      end
    end

    def hfa_literal_prefix_capture_each_scan_value(input, spec)
      _capture_number, prefix, host_run, path_run = spec
      host_table = host_run.first
      path_table = path_run.first
      position = 0
      while (start = input.index(prefix, position))
        cursor = start + prefix.bytesize
        cursor += 1 if input.getbyte(cursor) == 115
        unless input.index("://", cursor) == cursor
          position = start + prefix.bytesize
          next
        end

        host_start = cursor + 3
        host_finish = hfa_literal_prefix_capture_run_end(input, host_start, host_table)
        if host_finish == host_start
          position = start + prefix.bytesize
          next
        end

        finish = host_finish
        if input.getbyte(finish) == 47
          path_finish = hfa_literal_prefix_capture_run_end(input, finish + 1, path_table)
          finish = path_finish if path_finish > finish + 1
        end
        yield [input.byteslice(start, finish - start)]
        position = finish
      end
    end

    def hfa_capture_sequence_each_scan_value(input, spec)
      tokens, anchor = spec
      position = 0
      captures = Array.new(hfa_capture_count)
      offsets = Array.new(hfa_capture_count) { [nil, nil] }
      result_container = [nil, nil]
      while (start = hfa_capture_sequence_start(input, position, anchor))
        result = hfa_capture_sequence_match_result(input, start, tokens, captures, offsets, result_container)
        if result
          finish = result[0]
          yield captures.map { |offset| offset && input.byteslice(offset[0], offset[1] - offset[0]) }
          position = finish
        elsif anchor.first == :reverse
          delimiter_start = input.index(anchor[1], start + 1)
          position = delimiter_start ? delimiter_start + anchor[1].bytesize : input.bytesize
        else
          position = start + anchor[1].bytesize
        end
      end
    end

    def hfa_capture_sequence_single_operation_end(input, position, operation)
      kind = operation[0]
      table = operation[1]
      minimum = operation[2]
      if kind == :fixed
        minimum.times do
          return unless table[input.getbyte(position)]

          position += 1
        end
        return position
      end

      if kind == :literal
        return unless input.byteslice(position, table.bytesize) == table

        return position + table.bytesize
      end

      finish = hfa_literal_prefix_capture_run_end(input, position, table)
      finish - position >= minimum ? finish : nil
    end

    def hfa_scan_boundary_match?(input, start, finish, boundary)
      return true unless boundary

      if input.ascii_only?
        before = start.positive? && hfa_ascii_word_byte?(input.getbyte(start - 1))
        current = start < input.bytesize && hfa_ascii_word_byte?(input.getbyte(start))
        after_current = finish.positive? && hfa_ascii_word_byte?(input.getbyte(finish - 1))
        after = finish < input.bytesize && hfa_ascii_word_byte?(input.getbyte(finish))
      else
        before = start.positive? && CharacterPredicates.word?(input.getbyte(start - 1).chr)
        current = start < input.bytesize && CharacterPredicates.word?(input.getbyte(start).chr)
        after_current = finish.positive? && CharacterPredicates.word?(input.getbyte(finish - 1).chr)
        after = finish < input.bytesize && CharacterPredicates.word?(input.getbyte(finish).chr)
      end
      return before != current && after_current != after if boundary == :word_boundary

      before == current && after_current == after
    end

    def hfa_scan_boundary_start_match?(input, start, boundary)
      return true unless boundary

      if input.ascii_only?
        before = start.positive? && hfa_ascii_word_byte?(input.getbyte(start - 1))
        current = start < input.bytesize && hfa_ascii_word_byte?(input.getbyte(start))
      else
        before = start.positive? && CharacterPredicates.word?(input.getbyte(start - 1).chr)
        current = start < input.bytesize && CharacterPredicates.word?(input.getbyte(start).chr)
      end
      boundary == :word_boundary ? before != current : before == current
    end

    def replace_matches(input, replacement, block)
      if !block && replacement.index("\\").nil? && input.ascii_only? &&
         (spec = hfa_delimited_negated_class_result_spec)
        return [hfa_delimited_negated_class_replace_literal(input, replacement, spec), input.bytesize]
      end
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

    def hfa_delimited_negated_class_replace_literal(input, replacement, spec)
      prefix, suffix, minimum = spec
      result = String.new(encoding: input.encoding)
      cursor = 0
      position = 0
      while (start = input.index(prefix, position))
        finish = input.index(suffix, start + prefix.bytesize)
        unless finish
          position = start + prefix.bytesize
          next
        end

        if finish - start - prefix.bytesize >= minimum
          result << input.byteslice(cursor, start - cursor) << replacement
          cursor = finish + suffix.bytesize
          position = cursor
        else
          position = start + prefix.bytesize
        end
      end
      result << input.byteslice(cursor, input.bytesize - cursor) if cursor < input.bytesize
      result
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
      return hfa_generic_each_result(input, &block) unless hfa_each_result(input, &block)

      nil
    end

    def each_match(input, &block)
      raise TypeError, "no implicit conversion of #{input.class} into String" unless input.is_a?(String)

      return enum_for(__method__, input) unless block

      return nil if hfa_each_result(input) do |result|
        block.call(hfa_match_data(result, input))
      end

      hfa_generic_each_result(input) do |result|
        block.call(hfa_match_data(result, input))
      end
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
