# frozen_string_literal: true

module Onibi
  class AlternationCompiler
    def initialize(instructions, compile_node)
      @instructions = instructions
      @compile_node = compile_node
    end

    def compile(node)
      branch_starts, jumps = compile_branches(node)
      connect_branches(node, branch_starts, jumps)
    end

    private

    def compile_branches(node)
      splits = node.branches.length - 1
      emit(:split)
      branch_starts = []
      jumps = []
      node.branches.each_with_index do |branch, index|
        branch_starts << @instructions.length
        @compile_node.call(branch)
        jumps << emit(:jump) unless index == node.branches.length - 1
        emit(:split) if index < splits - 1
      end
      [branch_starts, jumps]
    end

    def connect_branches(node, branch_starts, jumps)
      end_target = @instructions.length
      jumps.each { |jump| jump.target = end_target }
      connect_split_operands(node, branch_starts)
      @instructions[0].target = branch_starts[1] if node.branches.length > 1
    end

    def connect_split_operands(node, branch_starts)
      node.branches.each_with_index do |_branch, index|
        next unless index < node.branches.length - 1

        instruction_index = index.zero? ? 0 : branch_starts[index] - 1
        @instructions[instruction_index].operand = branch_starts[index]
      end
    end

    def emit(opcode, operand = nil)
      instruction = Bytecode::Instruction.new(opcode, operand, nil)
      @instructions << instruction
      instruction
    end
  end
end
