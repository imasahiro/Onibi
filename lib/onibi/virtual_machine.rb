# frozen_string_literal: true

module Onibi
  # Executes Thompson bytecode without recursive backtracking.
  class VirtualMachine
    def initialize(program, options = [])
      @program = program
      @ignorecase = options.include?("ignorecase")
      @multiline = options.include?("multiline")
    end

    def match?(input)
      characters = if input.valid_encoding?
                     input.chars.map { |character| character.codepoints.first }
                   else
                     input.bytes
                   end

      (0..characters.length).any? { |start| match_from?(characters, start) }
    end

    private

    def match_from?(input, start)
      visited = {}

      run_state(0, start, input, visited)
    end

    def run_state(program_counter, position, input, visited)
      return false if visited[[program_counter, position]]

      visited[[program_counter, position]] = true
      instruction = instruction_at(program_counter)

      return true if instruction.opcode == :match

      dispatch_instruction(program_counter, position, input, visited, instruction)
    end

    def dispatch_instruction(program_counter, position, input, visited, instruction)
      return run_split(instruction, position, input, visited) if instruction.opcode == :split
      return run_state(instruction.target, position, input, visited) if instruction.opcode == :jump
      return run_state(program_counter + 1, position, input, visited) if tag_instruction?(instruction)
      return run_anchor(program_counter, instruction, position, input, visited) if instruction.opcode == :anchor

      consume_instruction(program_counter, position, input, visited, instruction)
    end

    def consume_instruction(program_counter, position, input, visited, instruction)
      return false unless position < input.length
      return false unless %i[char class escape any].include?(instruction.opcode)
      return false unless matches?(instruction, input[position])

      run_state(program_counter + 1, position + 1, input, visited)
    end

    def run_split(instruction, position, input, visited)
      first_branch = run_state(instruction.operand, position, input, visited)
      return true if first_branch

      run_state(instruction.target, position, input, visited)
    end

    def run_anchor(program_counter, instruction, position, input, visited)
      return false unless anchor_matches?(instruction.operand, position, input)

      run_state(program_counter + 1, position, input, visited)
    end

    def tag_instruction?(instruction)
      %i[save_start save_end].include?(instruction.opcode)
    end

    def consumable_instruction?(instruction, position, input)
      position < input.length && %i[char class escape any].include?(instruction.opcode) &&
        matches?(instruction, input[position])
    end

    def matches?(instruction, character)
      case instruction.opcode
      when :char then character_matches?(instruction.operand, character)
      when :any then true
      when :escape then escape_matches?(instruction.operand, character)
      when :class then class_matches?(instruction.operand, character)
      end
    end

    def escape_matches?(kind, character)
      case kind
      when :digit then character.between?("0".ord, "9".ord)
      when :space then CharacterPredicates.whitespace?(character)
      when :word then CharacterPredicates.word?(character)
      end
    end

    def class_matches?(source, character)
      negated = source.start_with?("^")
      codepoints = source[(negated ? 1 : 0)..].codepoints
      matched = class_codepoints_match?(codepoints, character)

      negated ? !matched : matched
    end

    def class_codepoints_match?(codepoints, character)
      codepoints.each_with_index.any? do |codepoint, index|
        next codepoint == character unless codepoints[index + 1] == "-".ord

        ending = codepoints[index + 2]
        ending && codepoint.upto(ending).include?(character)
      end
    end

    def character_matches?(source, character)
      return source.codepoints.first == character unless @ignorecase

      source.downcase.codepoints.first == character.chr.downcase.codepoints.first
    end

    def anchor_matches?(kind, position, input)
      return line_start?(position, input) if kind == :anchor_start
      return line_end?(position, input) if kind == :anchor_end

      false
    end

    def line_start?(position, input)
      position.zero? || (@multiline && input[position - 1] == "\n".ord)
    end

    def line_end?(position, input)
      position == input.length || (@multiline && input[position] == "\n".ord)
    end

    def instruction_at(program_counter)
      @program.instructions.fetch(program_counter)
    end
  end
end
