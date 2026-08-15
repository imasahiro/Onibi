# frozen_string_literal: true

module Onibi
  module RegexpCapturelessAlternationScan
    private

    def hfa_captureless_alternation_scan_spec
      return @hfa_captureless_alternation_scan_spec if defined?(@hfa_captureless_alternation_scan_spec)
      return @hfa_captureless_alternation_scan_spec = false unless @ast.is_a?(AST::Alternation)

      branches = @ast.branches.map { |branch| hfa_captureless_alternation_branch(branch) }
      valid = branches.all? && branches.length > 1
      @hfa_captureless_alternation_scan_spec = valid ? branches.freeze : false
    end

    def hfa_linebreak_alternation_scan_spec
      return @hfa_linebreak_alternation_scan_spec if defined?(@hfa_linebreak_alternation_scan_spec)
      return @hfa_linebreak_alternation_scan_spec = false unless @ast.is_a?(AST::Alternation)

      branches = @ast.branches.map { |branch| branch.is_a?(AST::Sequence) ? branch.parts : [branch] }
      marker_branch, newline_branch = branches.partition do |parts|
        parts.length == 3 && parts[0].is_a?(AST::Literal) && parts[0].value == ">" &&
          parts[1].is_a?(AST::Quantifier) && parts[1].kind == :* &&
          parts[1].expression.is_a?(AST::Any) &&
          parts[2].is_a?(AST::Literal) && parts[2].value == "\n"
      end
      valid = marker_branch.length == 1 && newline_branch.length == 1 &&
              newline_branch.first.length == 1 && newline_branch.first.first.is_a?(AST::Literal) &&
              newline_branch.first.first.value == "\n"
      @hfa_linebreak_alternation_scan_spec = valid
    end

    def hfa_linebreak_alternation_each_result(input)
      position = 0
      while (newline = input.index("\n", position))
        marker = input.index(">", position)
        start = marker && marker < newline ? marker : newline
        finish = newline + 1
        yield [start, finish, []]
        position = finish
      end
    end

    def hfa_captureless_alternation_branch(node)
      parts = node.is_a?(AST::Sequence) ? node.parts : [node]
      class_index = parts.index { |part| part.is_a?(AST::CharacterClass) }
      unless class_index
        literal = literal_ast_value(node)
        return literal && [:literal, literal].freeze
      end
      return unless parts.count { |part| part.is_a?(AST::CharacterClass) } == 1

      prefix_parts = parts.first(class_index)
      suffix_parts = parts.drop(class_index + 1)
      return unless (prefix_parts + suffix_parts).all? { |part| part.is_a?(AST::Literal) }

      prefix = prefix_parts.map(&:value).join
      suffix = suffix_parts.map(&:value).join
      return if prefix.empty? && suffix.empty?

      table = hfa_capture_class_table(parts[class_index])
      return unless table

      anchor = prefix.bytesize >= suffix.bytesize ? :prefix : :suffix
      [:class, prefix, suffix, table, anchor].freeze
    end

    def hfa_captureless_alternation_each_result(input, spec, &block)
      if spec.length == 2 && spec[0].first == :class && spec[0][1].bytesize == 1 &&
         spec[0][2].empty? && spec[1].first == :literal
        hfa_captureless_two_branch_each_result(input, spec, &block)
        return
      end

      position = 0
      while position < input.bytesize
        start = nil
        spec.each do |branch|
          candidate = if branch.first == :literal
                        input.index(branch[1], position)
                      else
                        prefix = branch[1]
                        suffix = branch[2]
                        anchor_side = branch[4]
                        anchor = anchor_side == :prefix ? prefix : suffix
                        anchor_position = position + (anchor_side == :prefix ? 0 : prefix.bytesize + 1)
                        found = input.index(anchor, anchor_position)
                        found -= prefix.bytesize + 1 if found && anchor_side == :suffix
                        found
                      end
          next unless candidate && (start.nil? || candidate < start)

          start = candidate
        end
        break unless start

        result = hfa_captureless_alternation_match_result(input, start, spec)
        if result
          yield [start, result, []]
          position = result
        else
          position = start + 1
        end
      end
    end

    def hfa_captureless_two_branch_each_result(input, spec)
      _kind, prefix, _suffix, table = spec[0]
      literal = spec[1][1]
      position = 0
      while position < input.bytesize
        class_start = input.index(prefix, position)
        literal_start = input.index(literal, position)
        start = if class_start && (literal_start.nil? || class_start <= literal_start)
                  class_start
                else
                  literal_start
                end
        break unless start

        if start == class_start && table[input.getbyte(start + 1)]
          finish = start + 2
        elsif start == literal_start
          finish = start + literal.bytesize
        else
          position = start + 1
          next
        end
        yield [start, finish, []]
        position = finish
      end
    end

    def hfa_captureless_alternation_match_result(input, start, spec)
      spec.each do |branch|
        return start + branch[1].bytesize if branch.first == :literal

        _kind, prefix, suffix, table, anchor_side = branch
        class_position = start + prefix.bytesize
        next unless anchor_side == :prefix || input.index(prefix, start) == start
        next unless table[input.getbyte(class_position)]
        next unless suffix.empty? || input.index(suffix, class_position + 1) == class_position + 1

        return class_position + suffix.bytesize + 1
      end
      nil
    end
  end
end
