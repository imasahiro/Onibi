# frozen_string_literal: true

module Onibi
  module RegexpCaptureScanOptimizations
    private

    def hfa_capture_run_end(input, position, table)
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
      return if prefix.empty? || steps.empty? || !hfa_alternation_capture_steps_safe?(steps)

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
            next_cursor = hfa_capture_run_end(input, cursor, value)
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
  end
end
