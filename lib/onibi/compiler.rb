# frozen_string_literal: true

module Onibi
  # Compiles AST nodes into Thompson-NFA instructions.
  class Compiler
    def initialize(ast)
      @ast = ast
      @instructions = []
    end

    def compile
      compile_node(@ast)
      emit(:match)
      Bytecode::Program.new(@instructions)
    end

    private

    # AST dispatch is intentionally explicit so each node maps to one opcode family.
    # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength
    def compile_node(node)
      case node
      when AST::Sequence then node.parts.each { |part| compile_node(part) }
      when AST::Alternation then compile_alternation(node)
      when AST::Group then compile_group(node)
      when AST::Quantifier then compile_quantifier(node)
      when AST::Literal then emit(:char, node.value)
      when AST::CharacterClass then emit(:class, node.value)
      when AST::Escape then emit(:escape, node.kind)
      when AST::Any then emit(:any)
      when AST::Anchor then emit(:anchor, node.kind)
      else raise ArgumentError, "unsupported AST node #{node.class}"
      end
    end
    # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength

    # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
    def compile_alternation(node)
      splits = node.branches.length - 1
      emit(:split)
      branch_starts = []
      jumps = []

      node.branches.each_with_index do |branch, index|
        branch_starts << @instructions.length
        compile_node(branch)
        jumps << emit(:jump) unless index == node.branches.length - 1
        emit(:split) if index < splits - 1
      end

      end_target = @instructions.length
      jumps.each { |jump| jump.target = end_target }
      node.branches.each_with_index do |_branch, index|
        next unless index < splits

        @instructions[index.zero? ? 0 : branch_starts[index] - 1].operand = branch_starts[index]
      end
      @instructions[0].target = branch_starts[1] if splits.positive?
    end
    # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

    def compile_group(node)
      emit(:save_start, node.number)
      compile_node(node.body)
      emit(:save_end, node.number)
    end

    def compile_quantifier(node)
      return compile_bounded(node) if node.kind == :bounded

      return compile_star(node) if node.kind == :*
      return compile_plus(node) if node.kind == :+

      split = emit(:split)
      body_start = @instructions.length
      compile_node(node.expression)
      split.operand = body_start
      split.target = @instructions.length
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
      emit(:repeat, [node.minimum, node.maximum])
      compile_node(node.expression)
    end

    def emit(opcode, operand = nil)
      instruction = Bytecode::Instruction.new(opcode, operand, nil)
      @instructions << instruction
      instruction
    end
  end
end
