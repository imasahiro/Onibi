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

    # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
    def run_state(program_counter, position, input, visited)
      return false if visited[[program_counter, position]]

      visited[[program_counter, position]] = true
      instruction = instruction_at(program_counter)
      return true if instruction.opcode == :match

      if instruction.opcode == :split
        first_branch = run_state(instruction.operand, position, input, visited)
        second_branch = run_state(instruction.target, position, input, visited)
        return first_branch || second_branch
      end
      return run_state(instruction.target, position, input, visited) if instruction.opcode == :jump
      if %i[save_start save_end].include?(instruction.opcode)
        return run_state(program_counter + 1, position, input, visited)
      end

      if instruction.opcode == :anchor
        if anchor_matches?(instruction.operand, position, input.length)
          return run_state(program_counter + 1, position, input, visited)
        end

        return false
      end
      return false unless position < input.length
      return false unless %i[char class escape any].include?(instruction.opcode)
      return false unless matches?(instruction, input[position])

      run_state(program_counter + 1, position + 1, input, visited)
    end
    # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

    def matches?(instruction, character)
      case instruction.opcode
      when :char then instruction.operand.codepoints.first == character
      when :any then true
      when :escape then escape_matches?(instruction.operand, character)
      when :class then class_matches?(instruction.operand, character)
      end
    end

    def escape_matches?(kind, character)
      case kind
      when :digit then character.between?("0".ord, "9".ord)
      when :space then character.chr =~ /\s/
      when :word then character.chr =~ /[A-Za-z0-9_]/
      end
    end

    # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
    def class_matches?(source, character)
      negated = source.start_with?("^")
      codepoints = source[(negated ? 1 : 0)..].codepoints
      matched = false
      index = 0

      while index < codepoints.length
        if codepoints[index + 1] == "-".ord && codepoints[index + 2]
          matched ||= codepoints[index].upto(codepoints[index + 2]).include?(character)
          index += 3
        else
          matched ||= codepoints[index] == character
          index += 1
        end
      end

      negated ? !matched : matched
    end
    # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

    def anchor_matches?(kind, position, input_length)
      (kind == :anchor_start && position.zero?) || (kind == :anchor_end && position == input_length)
    end

    def instruction_at(program_counter)
      @program.instructions.fetch(program_counter)
    end
  end
end
