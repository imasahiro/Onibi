# frozen_string_literal: true

module Onibi
  module RegexpCapturelessAlternationScan
    private

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
  end
end
