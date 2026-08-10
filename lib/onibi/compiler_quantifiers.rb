# frozen_string_literal: true

module Onibi
  # Compiles quantifier AST nodes into Thompson-NFA instructions.
  module CompilerQuantifiers
    private

    def compile_quantifier(node)
      return compile_bounded(node) if node.kind == :bounded

      return compile_star(node) if node.kind == :*
      return compile_plus(node) if node.kind == :+

      compile_optional(node.expression)
    end

    def compile_star(node)
      start_split = emit(:split)
      body_start = @instructions.length
      compile_node(node.expression)
      end_split = emit(:split)
      start_split.operand = body_start
      start_split.target = @instructions.length
      end_split.operand = body_start
      end_split.target = @instructions.length
    end

    def compile_plus(node)
      body_start = @instructions.length
      compile_node(node.expression)
      split = emit(:split)
      split.operand = body_start
      split.target = @instructions.length
    end

    def compile_bounded(node)
      node.minimum.times { compile_node(node.expression) }
      optional_count = node.maximum && node.maximum - node.minimum
      return compile_star(node.expression) unless optional_count

      optional_count.times { compile_optional(node.expression) }
    end

    def compile_optional(expression)
      split = emit(:split)
      body_start = @instructions.length
      compile_node(expression)
      split.operand = body_start
      split.target = @instructions.length
    end
  end
end
