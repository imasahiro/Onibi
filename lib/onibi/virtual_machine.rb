# frozen_string_literal: true

module Onibi
  # Executes Thompson bytecode without recursive backtracking.
  class VirtualMachine
    def initialize(program)
      @program = program
    end

    def match?(input)
      (0..input.length).any? { |start| match_from?(input, start) }
    end

    private

    def match_from?(input, start)
      position = start
      active = epsilon_closure([0], position, input.length)

      loop do
        return true if active.any? { |pc| instruction_at(pc).opcode == :match }
        return false if position >= input.length

        active = consume(active, input[position])
        position += 1
        active = epsilon_closure(active, position, input.length)
        return false if active.empty?
      end
    end

    def consume(states, character)
      states.each_with_object([]) do |pc, next_states|
        instruction = instruction_at(pc)
        next unless %i[char class escape any].include?(instruction.opcode)
        next unless matches?(instruction, character)

        next_states << pc + 1
      end
    end

    def epsilon_closure(states, position, input_length)
      pending = states.dup
      visited = {}
      result = []

      until pending.empty?
        pc = pending.pop
        next if visited[pc]

        visited[pc] = true
        instruction = instruction_at(pc)
        case instruction.opcode
        when :split then pending.push(instruction.operand, instruction.target)
        when :jump then pending << instruction.target
        when :save_start, :save_end then pending << pc + 1
        when :anchor then pending << pc + 1 if anchor_matches?(instruction.operand, position, input_length)
        else result << pc
        end
      end

      result
    end

    def matches?(instruction, character)
      case instruction.opcode
      when :char then instruction.operand == character
      when :any then true
      when :escape then escape_matches?(instruction.operand, character)
      when :class then instruction.operand.include?(character)
      end
    end

    def escape_matches?(kind, character)
      case kind
      when :digit then character >= "0" && character <= "9"
      when :space then character =~ /\s/
      when :word then character =~ /[A-Za-z0-9_]/
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
