# frozen_string_literal: true

module Onibi
  module IRGen
    module YARVIR
      module SemanticBytecode
        # `casefold` is the compiler-owned folded literal. `casefold_segments`
        # keeps each source character boundary for VM backtracking.
        # `fold_boundary_sensitive` tells the VM that MRI keeps this expanded
        # fold aligned with the following operand during backtracking.
        # `fold_boundary` describes a Unicode fold that has a special
        # operand-boundary rule. The VM consumes this metadata directly.
        Literal = Struct.new(:value, :casefold, :casefold_segments, :fold_boundary_sensitive,
                             :fold_boundary, :fold_prefix_boundary, :fold_policy)
        # `casefolds` contains reverse multi-character folds for this class.
        # `split_casefold` records MRI's class-only split rule for sharp-s.
        # `compiled_sensitive` and `compiled_insensitive` are immutable
        # predicate tables. The interpreter selects one table from flags.
        # It does not parse the class source during execution.
        CharacterClass = Struct.new(:value, :casefolds, :split_casefold,
                                    :compiled_sensitive, :compiled_insensitive,
                                    :folded_characters, :fold_boundaries, :fold_policy)
        Escape = Struct.new(:kind)
        # `casefolds` is compiler output. It prevents the interpreter from
        # consulting AST or rebuilding Unicode fold candidates at run time.
        Property = Struct.new(:name, :negated, :casefolds)
        Backreference = Struct.new(:identifier, :named)
        # `folded_widths` is the finite width set used by the VM for
        # encoding-aware lookbehind. It is compiler output, not AST state.
        Assertion = Struct.new(:body, :kind, :widths, :folded_widths)
        Any = Struct.new(:value)
        Anchor = Struct.new(:kind)
        Sequence = Struct.new(:parts)
        # `operand_context` marks an alternation that is the next operand in
        # a sequence. A root alternation selects a whole branch instead.
        Alternation = Struct.new(:branches, :operand_context)
        Group = Struct.new(:body, :number, :capture, :name)
        OptionGroup = Struct.new(:body, :ignorecase, :multiline, :extended)
        AtomicGroup = Struct.new(:body)
        Conditional = Struct.new(:condition, :yes_branch, :no_branch)
        SubexpressionCall = Struct.new(:identifier, :named)
        Absence = Struct.new(:body)
        # `lazy_exact` records MRI's special `{n}?` form. It accepts zero or
        # exactly `n` repetitions, not the intermediate counts.
        Quantifier = Struct.new(:expression, :kind, :minimum, :maximum, :mode, :lazy_exact)

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

        def compile(node, casefold: false, parent: nil)
          type = NODE_TYPES.fetch(node.class)
          if node.is_a?(Onibi::AST::Assertion)
            return type.new(compile_value(node.body, casefold: casefold), node.kind,
                            Onibi::WidthAnalysis.widths(node.body),
                            folded_widths(compile_value(node.body, casefold: casefold)))
          end
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
            # An expanded fold with distinct, non-mark code points can cross
            # operand boundaries in Onigmo. Derive this from fold structure,
            # not from a script-specific table.
            boundary_sensitive = folded.length > node.value.length &&
                                 folded.each_char.uniq.length > 1 &&
                                 folded.each_char.none? { |character| character.match?(/\p{M}/) }
            fold_boundary = fold_boundary_metadata(folded, boundary_sensitive)
            fold_prefix_boundary = fold_prefix_boundary_metadata(node.value)
            return type.new(node.value, folded == node.value ? nil : folded, segments&.freeze,
                            boundary_sensitive, fold_boundary, fold_prefix_boundary,
                            fold_policy_for_literal(node.value))
          end
          if node.is_a?(Onibi::AST::Sequence)
            parts = node.parts.map { |part| compile_value(part, casefold: casefold, parent: :sequence) }
            return type.new(parts)
          end
          if node.is_a?(Onibi::AST::Alternation)
            branches = node.branches.map { |branch| compile_value(branch, casefold: casefold, parent: :alternation) }
            return type.new(branches, parent == :sequence)
          end
          if node.is_a?(Onibi::AST::Group) || node.is_a?(Onibi::AST::OptionGroup) ||
             node.is_a?(Onibi::AST::AtomicGroup)
            body_parent = parent == :sequence ? :sequence : :group
            body_casefold = casefold || (node.respond_to?(:ignorecase) && node.ignorecase)
            body = compile_value(node.body, casefold: body_casefold, parent: body_parent)
            fields = node.each_pair.map { |field, value| field == :body ? body : compile_value(value, casefold: casefold) }
            return type.new(*fields)
          end
          if node.is_a?(Onibi::AST::CharacterClass)
            folds = class_casefold_sequences(node.value)
            split = folds.any? { |source, value| %w[ß ẞ].include?(source) && value == "ss" }
            folded_characters = casefold ? class_casefold_characters(node.value) : [].freeze
            return type.new(node.value, folds, split,
                            Onibi::ClassPredicates.compiled(node.value, ignorecase: false),
                            Onibi::ClassPredicates.compiled(node.value, ignorecase: true),
                            folded_characters,
                            class_fold_boundaries(folds, folded_characters),
                            fold_policy_for_class(node.value, folded_characters))
          end
          if node.is_a?(Onibi::AST::OptionGroup)
            body = compile_value(node.body, casefold: casefold || node.ignorecase)
            return type.new(body, node.ignorecase, node.multiline, node.extended)
          end
          if node.is_a?(Onibi::AST::Quantifier)
            minimum, maximum, lazy_exact = fold_lazy_exact_bounds(node)
            return type.new(compile_value(node.expression, casefold: casefold), node.kind,
                            minimum, maximum, node.mode, lazy_exact)
          end

          type.new(*node.each_pair.map { |_field, value| compile_value(value, casefold: casefold) })
        end

        def folded_widths(node)
          case node
          when SemanticBytecode::Literal
            [(node.casefold || node.value).length]
          when SemanticBytecode::CharacterClass
            [1, *node.casefolds.to_a.map { |_source, value| value.length }].uniq
          when SemanticBytecode::Property, SemanticBytecode::Any
            [1]
          when SemanticBytecode::Escape
            [zero_width_escape?(node.kind) ? 0 : 1]
          when SemanticBytecode::Anchor
            [0]
          when SemanticBytecode::Sequence
            node.parts.reduce([0]) do |widths, part|
              widths.product(folded_widths(part)).map { |left, right| left + right }.uniq
            end
          when SemanticBytecode::Alternation
            node.branches.flat_map { |branch| folded_widths(branch) }.uniq
          when SemanticBytecode::Group, SemanticBytecode::OptionGroup,
               SemanticBytecode::AtomicGroup, SemanticBytecode::Assertion
            folded_widths(node.body)
          when SemanticBytecode::Quantifier
            return [] unless node.maximum && node.minimum == node.maximum

            folded_widths(node.expression).map { |width| width * node.minimum }
          else
            []
          end
        end

        def zero_width_escape?(kind)
          %i[word_boundary not_word_boundary start_match match_reset].include?(kind)
        end

        # Onigmo treats an exact bound with a lazy suffix (`{n}?`) as a
        # bounded optional repeat. The bytecode stores that rule explicitly,
        # so the interpreter does not need to inspect the source AST.
        def fold_lazy_exact_bounds(node)
          return [node.minimum, node.maximum, false] unless node.kind == :bounded &&
                                                            node.mode == :lazy &&
                                                            node.exact_bound

          [0, node.maximum, true]
        end

        def class_casefold_sequences(source)
          Onibi::UnicodeProperties.casefold_codepoints.filter_map do |codepoint|
            character = [codepoint].pack("U")
            folded = character.downcase(:fold)
            [character, folded] if Onibi::ClassPredicates.matches?(source, character,
                                                                   encoding: source.encoding)
          end.freeze
        end

        def fold_boundary_metadata(folded, boundary_sensitive)
          return nil unless folded.encoding == Encoding::UTF_8
          return nil unless folded.length > 1 && folded.end_with?("ι")

          { kind: :expanded_tail, tail: folded.each_char.to_a.last,
            sensitive: boundary_sensitive }.freeze
        end

        def simple_fold_boundary_metadata(folded)
          variants = Onibi::UnicodeProperties.reverse_source_boundary_variants(folded)
          return if variants.empty?

          { kind: :simple_fold_source, variants: variants.freeze }.freeze
        end

        def fold_prefix_boundary_metadata(value)
          return nil unless value.encoding == Encoding::UTF_8

          normalized = value.unicode_normalize(:nfd)
          base = normalized.each_char.first
          marks = normalized.each_char.drop(1)
          return unless base == "ω" || marks.any? { |mark| %W[\u0300 \u0313 \u0314].include?(mark) }

          :non_split_prefix
        end

        # The VM receives semantic boundary policy. It does not identify
        # Unicode characters or infer policy from source text.
        def fold_policy_for_literal(value)
          group = Onibi::ClassPredicates.casefold_groups.values.find { |members| members.include?(value) }
          return nil unless group

          policy = {}
          if group.any? { |character| character.match?(/\p{M}/) }
            policy[:anchor_source] = :fold_group_variant
            policy[:alternation_source] = :reject_non_mark_variant
          end
          variants = Onibi::UnicodeProperties.reverse_source_boundary_variants(value.downcase(:fold))
          policy[:sequence_source] = :allow_repeated_variant if variants.any? && variants.all? { |character| character == character.upcase }
          policy.empty? ? nil : policy.freeze
        end

        def fold_policy_for_class(value, folded_characters)
          return nil unless value.each_char.one?
          return nil if folded_characters.empty?

          combining_variant = folded_characters.any? { |character| character.match?(/\p{M}/) }
          combining_variant ? { optional_order: :consume_source_variant }.freeze : nil
        end

        # MRI closes a range over every simple fold of every code point in
        # that range. For example, U+2126 OHM SIGN is inside [ẞ-龠], and its
        # fold U+03C9 makes Ω and ω valid class operands.
        def class_casefold_characters(source)
          return [].freeze unless source.encoding == Encoding::UTF_8
          return [].freeze if source.start_with?("^")

          metadata = Onibi::ClassPredicates::Normalizer.normalize(source)
          raw_match = if metadata.kind == :ascii
                        lambda do |member|
                          metadata.literals.include?(member) ||
                            metadata.ranges.any? { |first, last| member.ord.between?(first.ord, last.ord) }
                        end
                      else
                        ->(member) { ClassPredicates.matches?(source, member) }
                      end
          characters = Onibi::ClassPredicates.casefold_groups.each_value.with_object([]) do |members, result|
            next unless members.any? { |member| raw_match.call(member) }

            result.concat(members)
          end
          characters.uniq.freeze
        end

        def class_fold_boundaries(folds, folded_characters)
          characters = folds.map(&:first) | folded_characters
          characters.each_with_object({}) do |character, metadata|
            folded = character.downcase(:fold)
            simple = simple_fold_boundary_metadata(folded)
            if simple && simple[:variants].include?(character)
              metadata[character] = simple
              next
            end
            next unless folds.any? { |_source, value| value == folded }

            metadata[character] = fold_boundary_metadata(folded, true) ||
                                  simple_fold_boundary_metadata(folded)
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

        def compile_value(value, casefold: false, parent: nil)
          if value.respond_to?(:each_pair)
            compile(value, casefold: casefold, parent: parent)
          elsif value.is_a?(Array)
            value.map { |item| compile_value(item, casefold: casefold, parent: parent) }
          else
            value
          end
        end

        def casefold_required?(node)
          return true if node.is_a?(Onibi::AST::OptionGroup) && node.ignorecase

          node.respond_to?(:each_pair) && node.each_pair.any? do |_field, value|
            if value.respond_to?(:each_pair)
              casefold_required?(value)
            elsif value.is_a?(Array)
              value.any? { |item| item.respond_to?(:each_pair) && casefold_required?(item) }
            else
              false
            end
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
