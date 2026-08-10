# frozen_string_literal: true

module Onibi
  module Bytecode
    Instruction = Struct.new(:opcode, :operand, :target)

    class Program
      attr_reader :instructions

      def initialize(instructions)
        @instructions = instructions.freeze
      end

      def opcodes
        instructions.map(&:opcode)
      end
    end
  end
end
