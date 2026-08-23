# frozen_string_literal: true

module Onibi
  module IRGen
    module YARVIR
      Instruction = Struct.new(:opcode, :operand, keyword_init: true) do
        def initialize(opcode:, operand: nil) = super.freeze
      end

      Program = Struct.new(:instructions, :entry, :automaton, keyword_init: true) do
        def initialize(instructions:, entry: 0, automaton: nil)
          super(instructions: instructions.freeze, entry: entry, automaton: automaton)
          freeze
        end

        def iseq
          self
        end
      end
      ISeq = Program

      module_function

      def generate(automaton, mode: nil)
        mode ||= automaton.is_a?(Onibi::Automata::DFA) ? :dfa : :nfa
        return generate_nfa(automaton) if mode == :nfa

        generate_dfa(automaton)
      end

      def generate_dfa(dfa)
        instructions = [Instruction.new(opcode: :start, operand: dfa.start_state.id)]
        dfa.states.each do |state|
          dfa.transitions.each do |(source, label), target|
            next unless source == state.id

            instructions << Instruction.new(opcode: :match, operand: label)
            instructions << Instruction.new(opcode: :jump, operand: target)
          end
          instructions << Instruction.new(opcode: :accept, operand: state.id) if state.accepting
        end
        Program.new(instructions: instructions, automaton: dfa)
      end

      def generate_nfa(tnfa)
        instructions = [Instruction.new(opcode: :nfa_start, operand: tnfa.start_positions)]
        tnfa.transitions.each do |transition|
          instructions << Instruction.new(
            opcode: :nfa_match,
            operand: [transition.from, transition.to, [transition.operation.opcode, transition.operation.operand]]
          )
        end
        instructions << Instruction.new(opcode: :nfa_accept, operand: tnfa.accept_positions)
        Program.new(instructions: instructions, automaton: tnfa)
      end

      def generate_iseq(dfa)
        generate(dfa)
      end

      class Executor
        def initialize(program)
          @program = program
          @dfa = program.automaton
        end

        def match(input, start_position = 0)
          return nil unless @dfa.is_a?(Onibi::Automata::DFA)

          characters = input.each_char.to_a
          first = [start_position, 0].max
          first.upto(characters.length) do |start|
            state = @dfa.start_state.id
            cursor = start
            loop do
              transition = transitions_for(state).find do |label, _target|
                transition_length(label, characters, cursor)
              end
              break unless transition

              label, target = transition
              cursor += transition_length(label, characters, cursor)
              state = target
              return [start, cursor] if accepting?(state)
            end
          end
          nil
        end

        private

        def transitions_for(state)
          @dfa.transitions.filter_map do |(source, label), target|
            [label, target] if source == state
          end
        end

        def accepting?(state)
          @dfa.states.any? { |candidate| candidate.id == state && candidate.accepting }
        end

        def transition_length(label, characters, cursor)
          opcode, operand = label
          case opcode
          when :match_literal
            value = operand.value.each_char.to_a
            characters[cursor, value.length] == value ? value.length : nil
          when :match_class
            cursor < characters.length && Onibi::ClassPredicates.matches?(operand.value, characters[cursor]) ? 1 : nil
          when :match_any
            cursor < characters.length && (operand.value != "." || characters[cursor] != "\n") ? 1 : nil
          when :match_escape
            cursor < characters.length && Onibi::CharacterPredicates.escape_matches?(operand.kind, characters[cursor]) ? 1 : nil
          when :match_property
            if cursor < characters.length
              matched = Onibi::UnicodeProperties.matches?(operand.name, characters[cursor])
              matched = !matched if operand.negated
              matched ? 1 : nil
            end
          when :match_quantifier
            quantifier_length(operand, characters, cursor)
          when :match_group
            sequence_length(operand.body, characters, cursor)
          when :match_absence
            absence_length(operand, characters, cursor)
          end
        end

        def quantifier_length(quantifier, characters, cursor)
          count = 0
          limit = quantifier.maximum || (characters.length - cursor)
          while count < limit && cursor + count < characters.length &&
                atom_matches?(quantifier.expression, characters[cursor + count])
            count += 1
          end
          return nil if count < quantifier.minimum

          quantifier.mode == :lazy ? quantifier.minimum : count
        end

        def atom_matches?(expression, character)
          case expression
          when Onibi::AST::Literal then expression.value == character
          when Onibi::AST::CharacterClass then Onibi::ClassPredicates.matches?(expression.value, character)
          when Onibi::AST::Escape then Onibi::CharacterPredicates.escape_matches?(expression.kind, character)
          when Onibi::AST::Property then Onibi::UnicodeProperties.matches?(expression.name, character)
          when Onibi::AST::Any then expression.value != "." || character != "\n"
          else false
          end
        end

        def sequence_length(node, characters, cursor)
          parts = node.is_a?(Onibi::AST::Sequence) ? node.parts : [node]
          position = cursor
          parts.each do |part|
            length = case part
                     when Onibi::AST::Quantifier then quantifier_length(part, characters, position)
                     when Onibi::AST::Group then sequence_length(part.body, characters, position)
                     else transition_length([operation_for(part), part], characters, position)
                     end
            return nil unless length

            position += length
          end
          position - cursor
        end

        def operation_for(node)
          case node
          when Onibi::AST::Literal then :match_literal
          when Onibi::AST::CharacterClass then :match_class
          when Onibi::AST::Any then :match_any
          when Onibi::AST::Escape then :match_escape
          when Onibi::AST::Property then :match_property
          end
        end

        def absence_length(node, characters, cursor)
          delimiter = literal_value(node.body)
          return nil unless delimiter
          return cursor == characters.length ? 0 : nil if delimiter.empty?

          value = characters[cursor..]&.join.to_s
          index = value.index(delimiter)
          index ? index + delimiter.length - 1 : value.length
        end

        def literal_value(node)
          case node
          when Onibi::AST::Literal then node.value
          when Onibi::AST::Sequence
            node.parts.map { |part| literal_value(part) }.then { |values| values.all? ? values.join : nil }
          end
        end
      end

      def execute(program, input, start_position = 0)
        Executor.new(program).match(input, start_position)
      end
    end
  end
end
