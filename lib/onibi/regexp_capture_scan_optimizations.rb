# frozen_string_literal: true

module Onibi
  module RegexpCaptureScanOptimizations
    private

    def hfa_literal_prefix_capture_scan_spec
      return @hfa_literal_prefix_capture_scan_spec if defined?(@hfa_literal_prefix_capture_scan_spec)

      parts = @ast.is_a?(AST::Sequence) ? @ast.parts : []
      group = parts.one? && parts.first
      body = group.body if group.is_a?(AST::Group) && group.capture
      body_parts = body.parts if body.is_a?(AST::Sequence)
      prefix_parts = body_parts&.first(4)
      prefix = prefix_parts && literal_ast_value(AST::Sequence.new(prefix_parts))
      optional_s = body_parts&.[](4)
      scheme_parts = body_parts&.[](5, 3)
      scheme = scheme_parts && literal_ast_value(AST::Sequence.new(scheme_parts))
      host = body_parts&.[](8)
      optional_path = body_parts&.[](9)
      path_parts = optional_path.expression.body.parts if optional_path.is_a?(AST::Quantifier) &&
                                                          optional_path.kind == :"?" &&
                                                          optional_path.expression.is_a?(AST::Group) &&
                                                          optional_path.expression.body.is_a?(AST::Sequence)
      path_prefix, path_run = path_parts if path_parts&.length == 2
      host_run = hfa_literal_prefix_capture_run(host)
      path_class_run = hfa_literal_prefix_capture_run(path_run)
      valid = prefix == "http" &&
              optional_s.is_a?(AST::Quantifier) && optional_s.kind == :"?" &&
              optional_s.expression.is_a?(AST::Literal) && optional_s.expression.value == "s" &&
              scheme == "://" && host_run &&
              path_prefix.is_a?(AST::Literal) && path_prefix.value == "/" && path_class_run
      @hfa_literal_prefix_capture_scan_spec = if valid
                                                [group.number, prefix, host_run, path_class_run].freeze
                                              else
                                                false
                                              end
    end

    def hfa_literal_prefix_capture_run(node)
      return unless node.is_a?(AST::Quantifier) && node.kind == :+ && node.mode == :greedy

      table = hfa_capture_class_table(node.expression)
      table && [table, node.expression].freeze
    end

    def hfa_literal_prefix_capture_each_result(input, spec)
      capture_number, prefix, host_run, path_run = spec
      host_table = host_run.first
      path_table = path_run.first
      position = 0
      while (start = input.index(prefix, position))
        cursor = start + prefix.bytesize
        cursor += 1 if input.getbyte(cursor) == 115
        unless input.byteslice(cursor, 3) == "://"
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

        captures = Array.new(hfa_capture_count)
        captures[capture_number - 1] = [start, finish]
        yield [start, finish, captures]
        position = finish
      end
    end

    def hfa_literal_prefix_capture_run_end(input, position, table)
      finish = position
      finish += 1 while finish < input.bytesize && table[input.getbyte(finish)]
      finish
    end

    def hfa_alternation_capture_scan_spec
      return @hfa_alternation_capture_scan_spec if defined?(@hfa_alternation_capture_scan_spec)

      parts = @ast.is_a?(AST::Sequence) ? @ast.parts : []
      group = parts.one? && parts.first
      alternation = group.body if group.is_a?(AST::Group) && group.capture
      branches = alternation.branches if alternation.is_a?(AST::Alternation)
      compiled = branches&.map { |branch| hfa_alternation_capture_branch(branch) }
      valid = compiled&.all? && compiled.map(&:first).uniq.length == compiled.length
      @hfa_alternation_capture_scan_spec = if valid
                                             [group.number, compiled.freeze].freeze
                                           else
                                             false
                                           end
    end

    def hfa_alternation_capture_branch(node)
      parts = node.is_a?(AST::Sequence) ? node.parts : [node]
      prefix = +""
      steps = []
      parts.each do |part|
        if part.is_a?(AST::Literal) && steps.empty?
          prefix << part.value
          next
        end

        if part.is_a?(AST::Quantifier) && part.kind == :+ && part.mode == :greedy
          table = hfa_capture_class_table(part.expression)
          return unless table

          steps << [:class, table]
        elsif part.is_a?(AST::Literal)
          steps << [:literal, part.value]
        else
          return
        end
      end
      return if prefix.empty? || steps.empty?
      return unless hfa_alternation_capture_steps_safe?(steps)

      [prefix, steps.freeze].freeze
    end

    def hfa_alternation_capture_steps_safe?(steps)
      steps.each_with_index.all? do |(kind, value), index|
        next true unless kind == :class && steps[index + 1]

        next_kind, next_value = steps[index + 1]
        next_kind == :literal && !value[next_value.getbyte(0)]
      end
    end

    def hfa_alternation_capture_each_result(input, spec)
      capture_number, branches = spec
      position = 0
      while position < input.bytesize
        start = nil
        branches.each do |branch|
          candidate = input.index(branch.first, position)
          next unless candidate && (start.nil? || candidate < start)

          start = candidate
        end
        break unless start

        result = hfa_alternation_capture_match_result(input, start, branches)
        if result
          finish = result
          captures = Array.new(hfa_capture_count)
          captures[capture_number - 1] = [start, finish]
          yield [start, finish, captures]
          position = finish
        else
          position = start + 1
        end
      end
    end

    def hfa_alternation_capture_match_result(input, start, branches)
      branches.each do |prefix, steps|
        next unless input.index(prefix, start) == start

        cursor = start + prefix.bytesize
        valid = true
        steps.each do |kind, value|
          if kind == :literal
            unless input.index(value, cursor) == cursor
              valid = false
              break
            end

            cursor += value.bytesize
          else
            next_cursor = hfa_literal_prefix_capture_run_end(input, cursor, value)
            if next_cursor == cursor
              valid = false
              break
            end

            cursor = next_cursor
          end
        end
        return cursor if valid
      end
      nil
    end

    def hfa_capture_sequence_scan_spec
      return @hfa_capture_sequence_scan_spec if defined?(@hfa_capture_sequence_scan_spec)

      parts = @ast.is_a?(AST::Sequence) ? @ast.parts : []
      tokens = parts.map { |part| hfa_capture_sequence_token(part) }
      prefix = tokens.first&.[](1) if tokens.first&.first == :literal
      anchor = if prefix&.bytesize&.positive?
                 [:literal, prefix]
               elsif tokens.first&.first == :capture && tokens[1]&.first == :literal
                 operation = tokens.first[2].first
                 delimiter = tokens[1][1]
                 [:reverse, delimiter, operation[1]] if operation&.first == :class &&
                                                        delimiter.bytes.all? { |byte| !operation[1][byte] }
               end
      valid = anchor && tokens.all? && tokens.length > 1
      @hfa_capture_sequence_scan_spec = valid ? [tokens.freeze, anchor].freeze : false
    end

    def hfa_capture_sequence_token(node)
      return [:literal, node.value].freeze if node.is_a?(AST::Literal)

      if node.is_a?(AST::Group) && node.capture
        body = node.body.is_a?(AST::Sequence) ? node.body.parts : [node.body]
        operations = body.map { |part| hfa_capture_sequence_operation(part) }
        return if operations.any?(&:nil?)

        return [:capture, node.number, operations.freeze].freeze
      end

      operation = hfa_capture_sequence_operation(node)
      operation && [:raw, operation].freeze
    end

    def hfa_capture_sequence_operation(node)
      return [:literal, node.value].freeze if node.is_a?(AST::Literal)
      return unless node.is_a?(AST::Quantifier) && node.mode == :greedy

      table = hfa_capture_class_table(node.expression)
      return unless table
      return unless %i[+ bounded].include?(node.kind)

      [node.kind == :+ ? :class : :fixed, table, node.minimum, node.maximum].freeze
    end

    def hfa_capture_sequence_each_result(input, spec)
      tokens, anchor = spec
      position = 0
      while (start = hfa_capture_sequence_start(input, position, anchor))
        result = hfa_capture_sequence_match_result(input, start, tokens)
        if result
          finish, captures = result
          yield [start, finish, captures]
          position = finish
        elsif anchor.first == :reverse
          delimiter_start = input.index(anchor[1], start + 1)
          position = delimiter_start ? delimiter_start + anchor[1].bytesize : input.bytesize
        else
          position = start + anchor[1].bytesize
        end
      end
    end

    def hfa_capture_sequence_start(input, position, anchor)
      kind, value, table = anchor
      return input.index(value, position) if kind == :literal

      delimiter_start = input.index(value, position)
      return unless delimiter_start

      candidate = delimiter_start
      candidate -= 1 while candidate.positive? && table[input.getbyte(candidate - 1)]
      candidate
    end

    def hfa_capture_sequence_match_result(input, start, tokens, captures = nil, offsets = nil, result_container = nil)
      cursor = start
      captures ||= Array.new(hfa_capture_count)
      captures.fill(nil)
      offsets ||= Array.new(hfa_capture_count) { [nil, nil] }
      token_index = 0
      while token_index < tokens.length
        token = tokens[token_index]
        kind = token[0]
        case kind
        when :literal
          literal = token[1]
          return unless input.byteslice(cursor, literal.bytesize) == literal

          cursor += literal.bytesize
        when :capture
          number = token[1]
          operations = token[2]
          capture_start = cursor
          cursor = hfa_capture_sequence_operations_end(input, cursor, operations)
          return unless cursor

          offset = offsets[number - 1]
          offset[0] = capture_start
          offset[1] = cursor
          captures[number - 1] = offset
        when :raw
          cursor = hfa_capture_sequence_single_operation_end(input, cursor, token[1])
          return unless cursor
        end
        token_index += 1
      end
      if result_container
        result_container[0] = cursor
        result_container[1] = captures
        result_container
      else
        [cursor, captures]
      end
    end

    def hfa_capture_sequence_operations_end(input, position, operations)
      cursor = position
      index = 0
      while index < operations.length
        operation = operations[index]
        kind = operation[0]
        table = operation[1]
        minimum = operation[2]
        if kind == :literal
          return unless input.byteslice(cursor, table.bytesize) == table

          cursor += table.bytesize
          index += 1
          next
        end

        if kind == :fixed
          minimum.times do
            return unless table[input.getbyte(cursor)]

            cursor += 1
          end
          index += 1
          next
        end

        next_operation = operations[index + 1]
        if next_operation&.first == :literal && !table[next_operation[1].getbyte(0)]
          finish = hfa_capture_sequence_delimited_class_end(input, cursor, table, next_operation[1])
          return unless finish && finish - cursor >= minimum

          cursor = finish
          index += 1
          next
        end

        finish = hfa_literal_prefix_capture_run_end(input, cursor, table)
        return if finish - cursor < minimum

        return if next_operation&.first == :literal && table[next_operation[1].getbyte(0)]

        cursor = finish
        index += 1
      end
      cursor
    end
  end
end
