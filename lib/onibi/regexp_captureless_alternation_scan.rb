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

    def hfa_captureless_alternation_each_result(input, spec)
      position = 0
      while position < input.bytesize
        start = nil
        spec.each do |branch|
          candidate = if branch.first == :literal
                        input.index(branch[1], position)
                      else
                        prefix, suffix, _table, anchor_side = branch[1..]
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

    def hfa_captureless_alternation_match_result(input, start, spec)
      spec.each do |branch|
        if branch.first == :literal
          return start + branch[1].bytesize if input.byteslice(start, branch[1].bytesize) == branch[1]

          next
        end

        _kind, prefix, suffix, table, _anchor_side = branch
        class_position = start + prefix.bytesize
        next unless input.byteslice(start, prefix.bytesize) == prefix
        next unless table[input.getbyte(class_position)]
        next unless input.byteslice(class_position + 1, suffix.bytesize) == suffix

        return class_position + suffix.bytesize + 1
      end
      nil
    end
  end
end
