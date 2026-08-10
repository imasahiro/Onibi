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
      pending = [[0, start]]
      visited = {}

      until pending.empty?
        pc, position = pending.pop
        next if visited[[pc, position]]

        visited[[pc, position]] = true
        instruction = instruction_at(pc)
        case instruction.opcode
        when :match then return true
        when :split then pending.push([instruction.operand, position], [instruction.target, position])
        when :jump then pending << [instruction.target, position]
        when :save_start, :save_end then pending << [pc + 1, position]
        when :anchor
          pending << [pc + 1, position] if anchor_matches?(instruction.operand, position, input.length)
        when :char, :class, :escape, :any
          pending << [pc + 1, position + 1] if position < input.length && matches?(instruction, input[position])
        end
      end

      false
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
