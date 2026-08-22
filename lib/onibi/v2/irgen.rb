# frozen_string_literal: true

module Onibi
  module V2
    module IRGen
      module YARVIR
        Instruction = Struct.new(:opcode, :operand, keyword_init: true) do
          def initialize(opcode:, operand: nil) = super.freeze
        end
        Program = Struct.new(:instructions, :entry, keyword_init: true) do
          def initialize(instructions:, entry: 0)
            super(instructions: instructions.freeze, entry: entry)
            freeze
          end
        end

        module_function

        def generate(dfa)
          instructions = [Instruction.new(opcode: :start, operand: dfa.start_state.id)]
          dfa.states.each do |state|
            if state.id == dfa.start_state.id
              state.positions.each do |position|
                instructions << Instruction.new(opcode: :match, operand: position)
              end
            end
            dfa.transitions.each do |(source, label), target|
              next unless source == state.id

              instructions << Instruction.new(opcode: :match, operand: label)
              instructions << Instruction.new(opcode: :jump, operand: target)
            end
            instructions << Instruction.new(opcode: :accept, operand: state.id) if state.accepting
          end
          Program.new(instructions: instructions)
        end
      end
    end
  end
end
