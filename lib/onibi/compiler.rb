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

    def compile_alternation(node)
      splits = node.branches.length - 1
      split = emit(:split)
      branch_starts = []
      jumps = []

      node.branches.each_with_index do |branch, index|
        branch_starts << @instructions.length
        compile_node(branch)
        jumps << emit(:jump) unless index == node.branches.length - 1
        next_split = emit(:split) if index < splits - 1
        split = next_split if next_split
      end

      end_target = @instructions.length
      jumps.each { |jump| jump.target = end_target }
      node.branches.each_with_index do |_branch, index|
        next unless index < splits

        @instructions[index == 0 ? 0 : branch_starts[index] - 1].operand = branch_starts[index]
      end
      @instructions[0].target = branch_starts[1] if splits.positive?
    end

    def compile_group(node)
      emit(:save_start, node.number)
      compile_node(node.body)
      emit(:save_end, node.number)
    end

    def compile_quantifier(node)
      return compile_bounded(node) if node.kind == :bounded

      split = emit(:split)
      body_start = @instructions.length
      compile_node(node.expression)
      jump = emit(:jump)
      after = @instructions.length
      split.operand = body_start
      split.target = after if node.kind == :"?"
      jump.target = body_start if node.kind == :*
      jump.target = after if node.kind == :+
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
