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
  end
end
