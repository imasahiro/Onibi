# frozen_string_literal: true

module Onibi
  module IRGen
    module YARVIR
      module SemanticBytecode
        Literal = Struct.new(:value)
        CharacterClass = Struct.new(:value)
        Escape = Struct.new(:kind)
        Property = Struct.new(:name, :negated)
        Backreference = Struct.new(:identifier, :named)
        Assertion = Struct.new(:body, :kind)
        Any = Struct.new(:value)
        Anchor = Struct.new(:kind)
        Sequence = Struct.new(:parts)
        Alternation = Struct.new(:branches)
        Group = Struct.new(:body, :number, :capture, :name)
        OptionGroup = Struct.new(:body, :ignorecase, :multiline, :extended)
        AtomicGroup = Struct.new(:body)
        Conditional = Struct.new(:condition, :yes_branch, :no_branch)
        SubexpressionCall = Struct.new(:identifier, :named)
        Absence = Struct.new(:body)
        Quantifier = Struct.new(:expression, :kind, :minimum, :maximum, :mode)

        NODE_TYPES = {
          Onibi::AST::Literal => Literal,
          Onibi::AST::CharacterClass => CharacterClass,
          Onibi::AST::Escape => Escape,
          Onibi::AST::Property => Property,
          Onibi::AST::Backreference => Backreference,
          Onibi::AST::Assertion => Assertion,
          Onibi::AST::Any => Any,
          Onibi::AST::Anchor => Anchor,
          Onibi::AST::Sequence => Sequence,
          Onibi::AST::Alternation => Alternation,
          Onibi::AST::Group => Group,
          Onibi::AST::OptionGroup => OptionGroup,
          Onibi::AST::AtomicGroup => AtomicGroup,
          Onibi::AST::Conditional => Conditional,
          Onibi::AST::SubexpressionCall => SubexpressionCall,
          Onibi::AST::Absence => Absence,
          Onibi::AST::Quantifier => Quantifier
        }.freeze

        module_function

        def compile(node)
          type = NODE_TYPES.fetch(node.class)
          type.new(*node.each_pair.map { |_field, value| compile_value(value) })
        end

        def compile_value(value)
          if value.respond_to?(:each_pair)
            compile(value)
          elsif value.is_a?(Array)
            value.map { |item| compile_value(item) }
          else
            value
          end
        end

        # MatchData needs byte offsets when every literal is non-ASCII.
        # Keep this fact in the semantic bytecode, so the interpreter does
        # not need to inspect compiler AST nodes at runtime.
        def unicode_capture_byte_offsets?(node)
          return false if repeated_literal_capture?(node)

          literals = literal_values(node)
          literals.any? && literals.all? { |value| !value.ascii_only? }
        end

        def literal_values(node)
          case node
          when Literal then [node.value]
          when Sequence then node.parts.flat_map { |part| literal_values(part) }
          when Alternation then node.branches.flat_map { |branch| literal_values(branch) }
          when Group, OptionGroup, AtomicGroup, Assertion then literal_values(node.body)
          when Quantifier then literal_values(node.expression)
          else []
          end
        end

        def repeated_literal_capture?(node)
          return false unless node.is_a?(Sequence) && node.parts.length == 1

          group = node.parts.first
          return false unless group.is_a?(Group) && group.body.is_a?(Sequence) && group.body.parts.length == 1

          quantifier = group.body.parts.first
          quantifier.is_a?(Quantifier) && quantifier.expression.is_a?(Literal) &&
            !quantifier.expression.value.ascii_only?
        end
      end

      Instruction = Struct.new(:opcode, :operand, keyword_init: true) do
        def initialize(opcode:, operand: nil) = super.freeze
      end

      Program = Struct.new(:instructions, :entry, :automaton, :flags, keyword_init: true) do
        def initialize(instructions:, entry: 0, automaton: nil, flags: {})
          super(instructions: instructions.freeze, entry: entry, automaton: automaton, flags: flags.freeze)
          freeze
        end

        def iseq
          self
        end
      end
      ISeq = Program

      module_function

      def generate(automaton, mode: nil, flags: {})
        mode ||= automaton.is_a?(Onibi::Automata::DFA) ? :dfa : :nfa
        return generate_nfa(automaton, flags: flags) if mode == :nfa

        generate_dfa(automaton, flags: flags)
      end

      def generate_dfa(dfa, flags: {})
        instructions = [Instruction.new(opcode: :start, operand: dfa.start_state.id)]
        dfa.states.each do |state|
          dfa.transitions.each do |(source, label), target|
            next unless source == state.id

            instructions << Instruction.new(opcode: :match, operand: label)
            instructions << Instruction.new(opcode: :jump, operand: target)
          end
          instructions << Instruction.new(opcode: :accept, operand: state.id) if state.accepting
        end
        Program.new(instructions: instructions, automaton: dfa, flags: flags)
      end

      def generate_nfa(tnfa, flags: {})
        instructions = [Instruction.new(opcode: :nfa_start, operand: tnfa.start_positions)]
        tnfa.transitions.each do |transition|
          instructions << Instruction.new(
            opcode: :nfa_match,
            operand: [transition.from, transition.to, [transition.operation.opcode, transition.operation.operand]]
          )
        end
        instructions << Instruction.new(opcode: :nfa_accept, operand: tnfa.accept_positions)
        Program.new(instructions: instructions, automaton: tnfa, flags: flags)
      end

      def generate_iseq(dfa)
        generate(dfa)
      end

      def execute(program, input, start_position = 0)
        Onibi::Interpreter::Executor.new(program).match(input, start_position)
      end

      def execute_with_captures(program, input, start_position = 0)
        Onibi::Interpreter::Executor.new(program).match_with_captures(input, start_position)
      end
    end
  end
end
