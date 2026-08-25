# frozen_string_literal: true

module Onibi
  module IRGen
    module YARVIR
      module SemanticBytecode
        # `casefold` is the compiler-owned folded literal. `casefold_segments`
        # keeps each source character boundary for VM backtracking.
        # `fold_boundary_sensitive` tells the VM that MRI keeps this expanded
        # fold aligned with the following operand during backtracking.
        Literal = Struct.new(:value, :casefold, :casefold_segments, :fold_boundary_sensitive)
        # `casefolds` contains reverse multi-character folds for this class.
        # `split_casefold` records MRI's class-only split rule for sharp-s.
        CharacterClass = Struct.new(:value, :casefolds, :split_casefold)
        Escape = Struct.new(:kind)
        # `casefolds` is compiler output. It prevents the interpreter from
        # consulting AST or rebuilding Unicode fold candidates at run time.
        Property = Struct.new(:name, :negated, :casefolds)
        Backreference = Struct.new(:identifier, :named)
        Assertion = Struct.new(:body, :kind, :widths)
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
        TYPES = NODE_TYPES.values.freeze

        module_function

        def compile(node)
          type = NODE_TYPES.fetch(node.class)
          return type.new(compile_value(node.body), node.kind, Onibi::WidthAnalysis.widths(node.body)) if node.is_a?(Onibi::AST::Assertion)
          if node.is_a?(Onibi::AST::Property)
            return type.new(node.name, node.negated,
                            Onibi::UnicodeProperties.casefold_sequences(node.name))
          end
          if node.is_a?(Onibi::AST::Literal)
            folded = node.value.downcase(:fold)
            segments = node.value.each_char.map do |character|
              [character, character.downcase(:fold)]
            end
            segments = nil if segments.all? { |source, value| source == value }
            boundary_sensitive = folded.length > node.value.length &&
                                 folded.each_char.any? { |character| Onibi::UnicodeProperties.greek?(character) } &&
                                 folded.each_char.none? { |character| character.match?(/\p{M}/) }
            return type.new(node.value, folded == node.value ? nil : folded, segments&.freeze,
                            boundary_sensitive)
          end
          if node.is_a?(Onibi::AST::CharacterClass)
            folds = class_casefold_sequences(node.value)
            split = folds.any? { |source, value| %w[ß ẞ].include?(source) && value == "ss" }
            return type.new(node.value, folds, split)
          end

          type.new(*node.each_pair.map { |_field, value| compile_value(value) })
        end

        def class_casefold_sequences(source)
          Onibi::UnicodeProperties.casefold_codepoints.filter_map do |codepoint|
            character = [codepoint].pack("U")
            folded = character.downcase(:fold)
            [character, folded] if Onibi::ClassPredicates.matches?(source, character,
                                                                   encoding: source.encoding)
          end.freeze
        end

        def full_casefold?(node)
          case node
          when Literal
            node.value.downcase(:fold).length > node.value.length
          when Property
            node.casefolds.any?
          when CharacterClass
            node.casefolds.any?
          when Sequence
            node.parts.any? { |part| full_casefold?(part) }
          when Alternation
            node.branches.any? { |branch| full_casefold?(branch) }
          when Group, OptionGroup, AtomicGroup, Assertion
            full_casefold?(node.body)
          when Quantifier
            full_casefold?(node.expression)
          else
            false
          end
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

            instructions << Instruction.new(opcode: :match, operand: semantic_label(label))
            instructions << Instruction.new(opcode: :jump, operand: target)
          end
          instructions << Instruction.new(opcode: :accept, operand: state.id) if state.accepting
        end
        Program.new(instructions: instructions, automaton: semantic_automaton(dfa), flags: flags)
      end

      def generate_nfa(tnfa, flags: {})
        instructions = [Instruction.new(opcode: :nfa_start, operand: tnfa.start_positions)]
        tnfa.transitions.each do |transition|
          instructions << Instruction.new(
            opcode: :nfa_match,
            operand: [transition.from, transition.to,
                      [transition.operation.opcode, semantic_value(transition.operation.operand)]]
          )
        end
        instructions << Instruction.new(opcode: :nfa_accept, operand: tnfa.accept_positions)
        Program.new(instructions: instructions, automaton: semantic_automaton(tnfa), flags: flags)
      end

      # Automata are compiler output. Convert their operands before the
      # program reaches the interpreter. The VM then consumes semantic
      # operands and does not need AST objects at runtime.
      def semantic_automaton(automaton)
        copy = automaton.dup
        transitions = if automaton.is_a?(Onibi::Automata::DFA)
                        automaton.transitions.transform_keys do |(source, label)|
                          [source, semantic_label(label)]
                        end.freeze
                      else
                        automaton.transitions.map do |edge|
                          operation = edge.operation
                          semantic_operation = Onibi::CFG::Operation.new(
                            opcode: operation.opcode,
                            operand: semantic_value(operation.operand),
                            effects: operation.effects,
                            state_in: operation.state_in,
                            state_out: operation.state_out
                          )
                          Onibi::Automata::Transition.new(
                            from: edge.from, to: edge.to, operation: semantic_operation
                          )
                        end.freeze
                      end
        copy.instance_variable_set(:@transitions, transitions)
        copy.instance_variable_set(:@tnfa, nil) if automaton.is_a?(Onibi::Automata::DFA)
        copy
      end

      def semantic_label(label)
        [label[0], semantic_value(label[1])]
      end

      def semantic_value(value)
        return value if SemanticBytecode::TYPES.include?(value.class)

        if value.respond_to?(:each_pair)
          SemanticBytecode.compile(value)
        elsif value.is_a?(Array)
          value.map { |item| semantic_value(item) }
        else
          value
        end
      end

      def generate_iseq(dfa)
        generate(dfa)
      end

      def execute(program, input, start_position = 0, input_view: nil)
        Onibi::Interpreter::Executor.new(program, input_view: input_view).match(input, start_position)
      end

      def execute_with_captures(program, input, start_position = 0, input_view: nil)
        Onibi::Interpreter::Executor.new(program, input_view: input_view).match_with_captures(input, start_position)
      end
    end
  end
end
