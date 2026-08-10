# frozen_string_literal: true

module Onibi
  # Executes Thompson bytecode without recursive backtracking.
  class VirtualMachine
    def initialize(program)
      @program = program
    end

    def match?(input)
      characters = input.chars.map { |character| character.codepoints.first }

      (0..characters.length).any? { |start| match_from?(characters, start) }
    end

    private

    def match_from?(input, start)
      visited = {}

      run_state(0, start, input, visited)
    end

    def run_state(pc, position, input, visited)
      return false if visited[[pc, position]]

      visited[[pc, position]] = true
      instruction = instruction_at(pc)
      return true if instruction.opcode == :match
      return run_state(instruction.operand, position, input, visited) ||
        run_state(instruction.target, position, input, visited) if instruction.opcode == :split
      return run_state(instruction.target, position, input, visited) if instruction.opcode == :jump
      return run_state(pc + 1, position, input, visited) if %i[save_start save_end].include?(instruction.opcode)
      return run_state(pc + 1, position, input, visited) if instruction.opcode == :anchor && anchor_matches?(instruction.operand, position, input.length)
      return false unless position < input.length
      return false unless %i[char class escape any].include?(instruction.opcode)
      return false unless matches?(instruction, input[position])

      run_state(pc + 1, position + 1, input, visited)
    end

    def matches?(instruction, character)
      case instruction.opcode
      when :char then instruction.operand.codepoints.first == character
      when :any then true
      when :escape then escape_matches?(instruction.operand, character)
      when :class then instruction.operand.codepoints.include?(character)
      end
    end

    def escape_matches?(kind, character)
      case kind
      when :digit then character.between?("0".ord, "9".ord)
      when :space then character.chr =~ /\s/
      when :word then character.chr =~ /[A-Za-z0-9_]/
      end
    end

    def anchor_matches?(kind, position, input_length)
      (kind == :anchor_start && position.zero?) || (kind == :anchor_end && position == input_length)
    end

    def instruction_at(pc)
      @program.instructions.fetch(pc)
    end
  end
end
