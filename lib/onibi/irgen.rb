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

      class Executor
        def initialize(program)
          @program = program
          @automaton = program.automaton
          @subexpressions = program.flags[:subexpressions] || {}
        end

        def match(input, start_position = 0)
          result = run(input, start_position)
          result&.first(2)
        end

        def match_with_captures(input, start_position = 0)
          run(input, start_position)
        end

        private

        def run(input, start_position)
          characters = if input.encoding == Encoding::ASCII_8BIT
                         input.bytes.map { |byte| byte.chr(Encoding::ASCII_8BIT) }
                       else
                         input.codepoints.map { |codepoint| codepoint.chr(input.encoding) }
                       end
          @characters = characters
          @steps = 0
          first = [start_position, 0].max
          @match_start = first
          first.upto(characters.length) do |start|
            result = if (root = @program.flags[:semantic_root])
                       node_results(root, characters, start, {}, @program.flags).first&.then do |length, captures|
                         match_start = captures.delete(:__match_start) || start
                         match_reset = captures.delete(:__match_reset)
                         captures.delete(:__match_end)
                         captures.delete(:__match_probe)
                         captures.delete(:__match_prefix)
                         captures.delete(:__match_prefix_value)
                         captures.delete(:__match_alternative)
                         captures.delete(:__end_zero_width)
                         finish = match_reset ? start + length : match_start + length
                         [match_start, finish, captures]
                       end
                     elsif @automaton.is_a?(Onibi::Automata::DFA)
                       walk_dfa(@automaton.start_state.id, characters, start, {}, start, @program.flags)
                     elsif @automaton.is_a?(Onibi::Automata::GlushkovTNFA)
                       walk_tnfa(:start, characters, start, {}, start, @program.flags)
                     end
            return result if result
          end
          nil
        end

        def walk_dfa(state, characters, cursor, captures, start, flags)
          @steps += 1
          return nil if @steps > 2_000_000
          return [start, cursor, captures] if accepting?(state)

          transitions_for(state).each do |label, target|
            transition_results(label, characters, cursor, captures, flags).each do |length, inner_captures|
              next_captures = captures.dup
              next_captures.merge!(inner_captures)
              captures_for(label, cursor, length, next_captures, characters, flags)
              next_start = if label[0] == :match_escape && label[1].kind == :match_reset
                             cursor
                           else
                             start
                           end
              result = walk_dfa(target, characters, cursor + length, next_captures, next_start, flags)
              return result if result
            end
          end
          nil
        end

        def walk_tnfa(state, characters, cursor, captures, start, flags)
          @steps += 1
          return nil if @steps > 2_000_000
          return [start, cursor, captures] if tnfa_accepting?(state)

          transitions_for_tnfa(state).each do |edge|
            label = [edge.operation.opcode, edge.operation.operand]
            transition_results(label, characters, cursor, captures, flags).each do |length, inner_captures|
              next_captures = captures.dup
              next_captures.merge!(inner_captures)
              captures_for(label, cursor, length, next_captures, characters, flags)
              next_start = if label[0] == :match_escape && label[1].kind == :match_reset
                             cursor
                           else
                             start
                           end
              result = walk_tnfa(edge.to, characters, cursor + length, next_captures, next_start, flags)
              return result if result
            end
          end
          nil
        end

        def transition_results(label, characters, cursor, captures, flags = {})
          opcode, operand = label
          case opcode
          when :epsilon
            [[0, {}]]
          when :match_group
            node_results(operand.body, characters, cursor, captures, flags)
          when :match_atomic_group
            node_results(operand.body, characters, cursor, captures, flags).first(1)
          when :match_option_group
            node_results(operand.body, characters, cursor, captures,
                         flags.merge(ignorecase: operand.ignorecase, multiline: operand.multiline))
          when :match_quantifier
            quantifier_results(operand, characters, cursor, captures, flags)
          when :match_assertion
            assertion_results(operand, characters, cursor, captures, flags)
          when :match_subexpression_call
            node_results(operand, characters, cursor, captures, flags)
          when :match_absence
            absence_lengths(operand, characters, cursor, flags).map { |length| [length, {}] }
          when :match_class
            class_match_lengths(operand, characters, cursor, flags).map { |length| [length, {}] }
          else
            transition_lengths(label, characters, cursor, captures, flags).map { |length| [length, {}] }
          end
        end

        def assertion_results(assertion, characters, cursor, captures, flags = {})
          if %i[positive positive_lookahead].include?(assertion.kind)
            results = node_results(assertion.body, characters, cursor, captures, flags).first(1).map do |_length, inner|
              [0, inner]
            end
            return mark_end_zero_width(results, characters, cursor, flags)
          end

          if %i[negative negative_lookahead].include?(assertion.kind)
            matched = node_results(assertion.body, characters, cursor, captures, flags).any?
            return mark_end_zero_width(matched ? [] : [[0, captures]], characters, cursor, flags)
          end

          if assertion.kind == :positive_lookbehind
            return mark_end_zero_width(lookbehind_results(assertion.body, characters, cursor, captures, flags),
                                       characters, cursor, flags)
          end

          if assertion.kind == :negative_lookbehind
            matched = lookbehind_results(assertion.body, characters, cursor, captures, flags).any?
            return mark_end_zero_width(matched ? [] : [[0, captures]], characters, cursor, flags)
          end

          length = assertion_length(assertion, characters, cursor, flags)
          mark_end_zero_width(length ? [[0, captures]] : [], characters, cursor, flags)
        end

        def mark_end_zero_width(results, characters, cursor, flags)
          return results unless flags[:multiline] && cursor == characters.length

          results.map do |length, state|
            next [length, state] unless length.zero?

            marked = state.dup
            marked[:__end_zero_width] = true
            [length, marked]
          end
        end

        def lookbehind_results(body, characters, cursor, captures, flags)
          0.upto(cursor).reverse_each do |width|
            results = node_results(body, characters, cursor - width, captures, flags)
            matching = results.select { |length, _inner| length == width }
            return matching.map { |_length, inner| [0, inner] } unless matching.empty?
          end
          []
        end

        def node_results(node, characters, cursor, captures, flags = {})
          @steps += 1
          return [] if @steps > 2_000_000

          case node
          when Onibi::AST::Sequence, SemanticBytecode::Sequence
            states = [[0, captures]]
            node.parts.each do |part|
              states = states.flat_map do |consumed, state_captures|
                node_results(part, characters, cursor + consumed, state_captures, flags).map do |length, inner|
                  next_state = if node.parts.length > 1 && inner.key?(:__match_start) && !inner.key?(:__match_prefix)
                                 marked = inner.dup
                                 marked[:__match_prefix] = consumed
                                 marked[:__match_prefix_value] = characters[cursor, consumed].join
                                 marked
                               else
                                 inner
                               end
                  [consumed + length, next_state]
                end
              end
              return [] if states.empty?
            end
            states
          when Onibi::AST::Alternation, SemanticBytecode::Alternation
            node.branches.flat_map do |branch|
              node_results(branch, characters, cursor, captures, flags).map do |length, state|
                next [length, state] unless state.key?(:__match_start)

                marked = state.dup
                marked[:__match_alternative] = true
                [length, marked]
              end
            end
          when Onibi::AST::Group, SemanticBytecode::Group
            node_results(node.body, characters, cursor, captures, flags).map do |length, inner|
              next_captures = inner.dup
              if node.capture
                next_captures[node.number] = [cursor, cursor + length]
                next_captures[node.name] = [cursor, cursor + length] if node.name
              end
              [length, next_captures]
            end
          when Onibi::AST::Quantifier, SemanticBytecode::Quantifier
            quantifier_results(node, characters, cursor, captures, flags)
          when Onibi::AST::OptionGroup, SemanticBytecode::OptionGroup
            scoped_flags = flags.dup
            scoped_flags[:ignorecase] = node.ignorecase unless node.ignorecase.nil?
            scoped_flags[:multiline] = node.multiline unless node.multiline.nil?
            node_results(node.body, characters, cursor, captures, scoped_flags)
          when Onibi::AST::AtomicGroup, SemanticBytecode::AtomicGroup
            node_results(node.body, characters, cursor, captures, flags).first(1)
          when Onibi::AST::Assertion, SemanticBytecode::Assertion
            assertion_results(node, characters, cursor, captures, flags)
          when Onibi::AST::SubexpressionCall, SemanticBytecode::SubexpressionCall
            body = @subexpressions[node.identifier]
            return [] unless body
            return [] if (@subexpression_depth ||= 0) > 32

            @subexpression_depth += 1
            results = node_results(body, characters, cursor, captures, flags)
            @subexpression_depth -= 1
            results
          when Onibi::AST::Absence, SemanticBytecode::Absence
            absence_results(node, characters, cursor, captures, flags)
          else
            length = transition_length([operation_for(node), node], characters, cursor, flags, captures)
            return [] unless length

            if (node.is_a?(Onibi::AST::Escape) || node.is_a?(SemanticBytecode::Escape)) && node.kind == :match_reset
              next_captures = captures.dup
              next_captures[:__match_start] = cursor
              next_captures[:__match_reset] = true
              return [[length, next_captures]]
            end

            if length.zero? && flags[:multiline] && cursor == characters.length &&
               (node.is_a?(Onibi::AST::Anchor) || node.is_a?(SemanticBytecode::Anchor))
              marked = captures.dup
              marked[:__end_zero_width] = true
              return [[length, marked]]
            end

            [[length, captures]]
          end
        end

        def quantifier_results(quantifier, characters, cursor, captures, flags = {})
          if captures[:__end_zero_width] && characters.join.bytesize > 1 && flags[:multiline] &&
             quantifier.mode != :lazy &&
             quantifier.minimum.zero? && quantifier.maximum.nil? &&
             (quantifier.expression.is_a?(Onibi::AST::Any) || quantifier.expression.is_a?(SemanticBytecode::Any)) &&
             quantifier.expression.value == "."
            return []
          end

          return possessive_quantifier_results(quantifier, characters, cursor, captures, flags) if quantifier.mode == :possessive

          ordered_quantifier_results(quantifier, characters, cursor, captures, flags)
        end

        def ordered_quantifier_results(quantifier, characters, cursor, captures, flags)
          limit = quantifier.maximum || characters.length - cursor + 1
          accepted = []
          visit = lambda do |consumed, state_captures, count|
            current = [consumed, state_captures]
            if (count >= quantifier.minimum) && (quantifier.mode == :lazy)
              accepted << current unless accepted.include?(current)
              return if count >= limit
            end
            if count >= limit
              accepted << current unless accepted.include?(current) || count < quantifier.minimum
              return
            end

            node_results(quantifier.expression, characters, cursor + consumed, state_captures, flags).each do |length, inner|
              if length.zero?
                expression = quantifier.expression
                expression = expression.body if expression.is_a?(Onibi::AST::Group) ||
                                                expression.is_a?(SemanticBytecode::Group)
                next if count.positive? && consumed.positive? &&
                        (expression.is_a?(Onibi::AST::Sequence) ||
                         expression.is_a?(SemanticBytecode::Sequence))

                accepted << [consumed, inner] if count + 1 >= quantifier.minimum
                visit.call(consumed, inner, count + 1) if count + 1 < quantifier.minimum
                next
              end
              visit.call(consumed + length, inner, count + 1)
            end
            accepted << current if quantifier.mode != :lazy && count >= quantifier.minimum && !accepted.include?(current)
          end
          visit.call(0, captures, 0)
          return [] if accepted.empty?

          if quantifier.mode != :lazy && nullable_single_quantifier?(quantifier.expression)
            accepted = accepted.group_by(&:first).values.map(&:last).sort_by { |length, _state| -length }
            group = quantifier.expression
            accepted = accepted.map do |length, state|
              next_state = state.dup
              next_state[group.number] = [cursor + length, cursor + length]
              [length, next_state]
            end
          end

          accepted
        end

        def nullable_single_quantifier?(node)
          group = node if node.is_a?(Onibi::AST::Group) || node.is_a?(SemanticBytecode::Group)
          body = group&.body
          parts = body.is_a?(Onibi::AST::Sequence) || body.is_a?(SemanticBytecode::Sequence) ? body.parts : [body]
          nested = parts.first
          nested && (nested.is_a?(Onibi::AST::Quantifier) || nested.is_a?(SemanticBytecode::Quantifier)) &&
            nested.minimum.zero? && nested.maximum == 1
        end

        def legacy_quantifier_results(quantifier, characters, cursor, captures, flags = {})
          limit = quantifier.maximum || characters.length - cursor
          frontier = [[0, captures]]
          accepted = quantifier.minimum.zero? ? frontier.dup : []
          count = 0
          while count < limit
            next_frontier = frontier.flat_map do |consumed, state_captures|
              zero_results = []
              nonzero_results = node_results(quantifier.expression, characters, cursor + consumed, state_captures, flags).filter_map do |length, inner|
                if length.zero?
                  zero_results << [consumed, inner]
                  next
                end
                [consumed + length, inner]
              end
              accepted.concat(zero_results) if count + 1 >= quantifier.minimum
              nonzero_results
            end
            if next_frontier.empty?
              count += 1 if count + 1 >= quantifier.minimum && accepted.any?
              break
            end

            count += 1
            frontier = next_frontier
            accepted.concat(frontier) if count >= quantifier.minimum
          end
          return [] if count < quantifier.minimum

          accepted = accepted.uniq { |length, state| [length, state] }
          if quantifier.mode == :lazy
            accepted.each_with_index.sort_by { |(state, index)| [state.first, index] }.map(&:first)
          else
            accepted.each_with_index.sort_by { |(state, index)| [-state.first, -index] }.map(&:first)
          end
        end

        def possessive_quantifier_results(quantifier, characters, cursor, captures, flags)
          limit = quantifier.maximum || characters.length - cursor
          consumed = 0
          current = captures
          count = 0
          accepted = quantifier.minimum.zero? ? [[0, current]] : []
          while count < limit
            result = node_results(quantifier.expression, characters, cursor + consumed, current, flags).find do |length, _state|
              length.positive? || count + 1 >= quantifier.minimum
            end
            break unless result

            length, current = result
            consumed += length
            count += 1
            accepted << [consumed, current] if count >= quantifier.minimum
            break if length.zero?
          end
          return [] if count < quantifier.minimum

          [accepted.last]
        end

        def transition_lengths(label, characters, cursor, captures, flags = {})
          opcode, operand = label
          return quantifier_lengths(operand, characters, cursor) if opcode == :match_quantifier

          length = transition_length(label, characters, cursor, flags, captures)
          length ? [length] : []
        end

        def transitions_for(state)
          @automaton.transitions.filter_map do |(source, label), target|
            [label, target] if source == state
          end
        end

        def accepting?(state)
          @automaton.states.any? { |candidate| candidate.id == state && candidate.accepting }
        end

        def transitions_for_tnfa(state)
          @automaton.transitions.select { |edge| edge.from == state }
        end

        def tnfa_accepting?(state)
          @automaton.accept_positions.include?(state)
        end

        def transition_length(label, characters, cursor, flags = {}, captures = {})
          opcode, operand = label
          case opcode
          when :match_literal
            value = operand.value.each_char.to_a
            if flags[:ignorecase]
              (value.length..(value.length * 2)).find do |length|
                candidate = characters[cursor, length].to_a.join
                casefold_equal?(value.join, candidate)
              end
            else
              characters[cursor, value.length] == value ? value.length : nil
            end
          when :match_class
            class_match_lengths(operand, characters, cursor, flags).first
          when :match_any
            cursor < characters.length && (flags[:multiline] || operand.value != "." || characters[cursor] != "\n") ? 1 : nil
          when :match_escape
            case operand.kind
            when :word_boundary, :not_word_boundary
              left = cursor.positive? && boundary_word?(characters[cursor - 1])
              right = cursor < characters.length && boundary_word?(characters[cursor])
              boundary = left != right
              boundary = !boundary if operand.kind == :not_word_boundary
              boundary ? 0 : nil
            when :linebreak
              return nil unless cursor < characters.length && Onibi::CharacterPredicates.linebreak?(characters[cursor])

              characters[cursor] == "\r" && characters[cursor + 1] == "\n" ? 2 : 1
            when :match_reset
              0
            when :start_match
              cursor == @match_start ? 0 : nil
            else
              cursor < characters.length && Onibi::CharacterPredicates.escape_matches?(operand.kind, characters[cursor]) ? 1 : nil
            end
          when :match_property
            if cursor < characters.length
              matched = property_matches?(operand.name, unicode_character(characters[cursor]), flags[:ignorecase])
              matched = !matched if operand.negated
              matched ? 1 : nil
            end
          when :match_quantifier
            quantifier_length(operand, characters, cursor)
          when :match_group
            sequence_length(operand.body, characters, cursor)
          when :match_backreference
            backreference_length(operand, characters, cursor, captures, flags)
          when :match_conditional
            conditional_length(operand, characters, cursor, captures)
          when :match_atomic_group
            sequence_length(operand.body, characters, cursor)
          when :match_option_group
            option_group_length(operand, characters, cursor, flags)
          when :match_absence
            absence_length(operand, characters, cursor, flags)
          when :match_assertion
            assertion_length(operand, characters, cursor, flags)
          when :test_anchor
            anchor_length(operand, characters, cursor)
          end
        end

        def quantifier_length(quantifier, characters, cursor, flags = {})
          if quantifier.expression.is_a?(Onibi::AST::Group) || quantifier.expression.is_a?(SemanticBytecode::Group)
            count = 0
            consumed = 0
            limit = quantifier.maximum || characters.length
            while count < limit
              unit = sequence_length(quantifier.expression.body, characters, cursor + consumed, flags)
              break unless unit&.positive?

              count += 1
              consumed += unit
            end
            return nil if count < quantifier.minimum

            return quantifier.mode == :lazy ? sequence_length(quantifier.expression.body, characters, cursor, flags) : consumed
          end

          count = 0
          limit = quantifier.maximum || (characters.length - cursor)
          while count < limit && cursor + count < characters.length &&
                atom_matches?(quantifier.expression, characters[cursor + count], flags)
            count += 1
          end
          return nil if count < quantifier.minimum

          quantifier.mode == :lazy ? quantifier.minimum : count
        end

        def quantifier_lengths(quantifier, characters, cursor)
          if quantifier.expression.is_a?(Onibi::AST::Group) || quantifier.expression.is_a?(SemanticBytecode::Group)
            unit = sequence_length(quantifier.expression.body, characters, cursor)
            return [] unless unit&.positive?

            count = 0
            consumed = 0
            limit = quantifier.maximum || characters.length
            lengths = []
            while count < limit
              unit_length = sequence_length(quantifier.expression.body, characters, cursor + consumed)
              break unless unit_length&.positive?

              count += 1
              consumed += unit_length
              lengths << consumed if count >= quantifier.minimum
            end
            return [lengths.last] if quantifier.mode == :possessive

            return quantifier.mode == :lazy ? lengths : lengths.reverse
          end

          count = 0
          limit = quantifier.maximum || (characters.length - cursor)
          while count < limit && cursor + count < characters.length &&
                atom_matches?(quantifier.expression, characters[cursor + count])
            count += 1
          end
          return [] if count < quantifier.minimum

          lengths = (quantifier.minimum..count).to_a
          return [lengths.last] if quantifier.mode == :possessive

          quantifier.mode == :lazy ? lengths : lengths.reverse
        end

        def captures_for(label, cursor, length, captures, characters = nil, flags = {})
          opcode, operand = label
          if opcode == :match_absence
            capture_absence(operand.body, cursor, length, captures)
            return
          end
          if opcode == :match_quantifier &&
             (operand.expression.is_a?(Onibi::AST::Group) || operand.expression.is_a?(SemanticBytecode::Group))
            group = operand.expression
            return unless group.capture && length.positive?

            captures[group.number] ||= [cursor, cursor + length]
            captures[group.name] ||= [cursor, cursor + length] if group.name
            return
          end
          return unless opcode == :match_group && operand.capture

          captures[operand.number] = [cursor, cursor + length]
          captures[operand.name] = [cursor, cursor + length] if operand.name
          return unless characters

          nested = node_results(operand.body, characters, cursor, captures, flags).find do |inner_length, _inner|
            inner_length == length
          end
          captures.merge!(nested[1]) if nested
        end

        def capture_absence(node, cursor, _length, captures)
          return unless node.is_a?(Onibi::AST::Sequence) || node.is_a?(SemanticBytecode::Sequence)

          group = node.parts.find do |part|
            (part.is_a?(Onibi::AST::Group) || part.is_a?(SemanticBytecode::Group)) && part.capture
          end
          return unless group

          value = literal_value(group.body)
          return unless value

          relative_start = @characters[cursor..]&.join.to_s.index(value)
          return unless relative_start

          delimiter_start = cursor + relative_start
          captures[group.number] = [delimiter_start, delimiter_start + value.length]
          captures[group.name] = [delimiter_start, delimiter_start + value.length] if group.name
        end

        def backreference_length(reference, characters, cursor, captures, flags = {})
          identifiers = if reference.named && flags[:named_capture_numbers]
                          flags[:named_capture_numbers][reference.identifier] || [reference.identifier]
                        else
                          [reference.identifier]
                        end
          identifiers.each do |identifier|
            span = captures[identifier]
            next unless span

            value = characters[span[0]...span[1]]
            candidate = characters[cursor, value.length]
            matched = flags[:ignorecase] ? casefold_equal?(value.join, candidate.join) : candidate == value
            return value.length if matched
          end
          nil
        end

        def conditional_length(conditional, characters, cursor, captures)
          condition = conditional.condition
          key = condition.is_a?(Array) ? condition[0] : condition
          branch = captures.key?(key) ? conditional.yes_branch : conditional.no_branch
          return nil unless branch

          sequence_length(branch, characters, cursor)
        end

        def atom_matches?(expression, character, flags = {})
          case expression
          when Onibi::AST::Literal, SemanticBytecode::Literal
            flags[:ignorecase] ? expression.value.casecmp?(character) : expression.value == character
          when Onibi::AST::CharacterClass, SemanticBytecode::CharacterClass
            Onibi::ClassPredicates.matches?(expression.value, character)
          when Onibi::AST::Escape, SemanticBytecode::Escape
            Onibi::CharacterPredicates.escape_matches?(expression.kind, character)
          when Onibi::AST::Property, SemanticBytecode::Property
            matched = property_matches?(expression.name, character, flags[:ignorecase] && !expression.negated)
            expression.negated ? !matched : matched
          when Onibi::AST::Any, SemanticBytecode::Any
            flags[:multiline] || expression.value != "." || character != "\n"
          else false
          end
        end

        def sequence_length(node, characters, cursor, flags = {})
          parts = if node.is_a?(Onibi::AST::Sequence) || node.is_a?(SemanticBytecode::Sequence)
                    node.parts
                  else
                    [node]
                  end
          position = cursor
          parts.each do |part|
            length = case part
                     when Onibi::AST::Quantifier, SemanticBytecode::Quantifier
                       quantifier_length(part, characters, position, flags)
                     when Onibi::AST::Group, SemanticBytecode::Group
                       sequence_length(part.body, characters, position, flags)
                     else transition_length([operation_for(part), part], characters, position, flags)
                     end
            return nil unless length

            position += length
          end
          position - cursor
        end

        def option_group_length(group, characters, cursor, flags = {})
          scoped_flags = flags.dup
          scoped_flags[:ignorecase] = group.ignorecase unless group.ignorecase.nil?
          scoped_flags[:multiline] = group.multiline unless group.multiline.nil?
          sequence_length(group.body, characters, cursor, scoped_flags)
        end

        def operation_for(node)
          case node
          when Onibi::AST::Literal, SemanticBytecode::Literal then :match_literal
          when Onibi::AST::CharacterClass, SemanticBytecode::CharacterClass then :match_class
          when Onibi::AST::Any, SemanticBytecode::Any then :match_any
          when Onibi::AST::Escape, SemanticBytecode::Escape then :match_escape
          when Onibi::AST::Property, SemanticBytecode::Property then :match_property
          when Onibi::AST::Backreference, SemanticBytecode::Backreference then :match_backreference
          when Onibi::AST::Conditional, SemanticBytecode::Conditional then :match_conditional
          when Onibi::AST::Absence, SemanticBytecode::Absence then :match_absence
          when Onibi::AST::Assertion, SemanticBytecode::Assertion then :match_assertion
          when Onibi::AST::Anchor, SemanticBytecode::Anchor then :test_anchor
          end
        end

        def absence_length(node, characters, cursor, flags = {})
          delimiter = literal_value(node.body)
          return generic_absence_length(node, characters, cursor, flags) unless delimiter
          return 0 if delimiter.empty? && cursor == characters.length
          return nil if delimiter.empty?

          value = characters[cursor..]&.join.to_s
          index = value.index(delimiter)
          index ? index + delimiter.length - 1 : value.length
        end

        def absence_lengths(node, characters, cursor, flags = {})
          maximum = absence_length(node, characters, cursor, flags)
          return [] if maximum.nil?

          maximum.downto(0).to_a
        end

        def absence_results(node, characters, cursor, captures, flags)
          delimiter = literal_value(node.body)
          return absence_lengths(node, characters, cursor, flags).map { |length| [length, captures] } if delimiter

          body_at_cursor = node_results(node.body, characters, cursor, captures, flags)
          first_length = body_at_cursor.first&.first
          first_state = body_at_cursor.first&.last || {}
          zero_at_cursor = first_length&.zero?
          consuming_at_cursor = first_length&.positive?
          return [] if zero_at_cursor && consuming_at_cursor

          if zero_at_cursor && !consuming_at_cursor
            later_consuming = cursor.upto(characters.length).any? do |position|
              node_results(node.body, characters, position, captures, flags).any? do |length, _state|
                length.positive?
              end
            end
            shifted = first_state[:__match_start].is_a?(Integer) && first_state[:__match_start] > cursor
            return [] if later_consuming && !shifted
          end

          zero_width = zero_width_absence_results(node.body, characters, cursor, captures, flags)
          return zero_width if zero_width

          return [] if zero_width_star_absence?(node.body, characters, cursor)

          quantified = quantified_absence_length(node.body, characters, cursor)
          if quantified
            body_results = node_results(node.body, characters, cursor, captures, flags)
            body_result = body_results.find { |length, _state| length.positive? } || body_results.first
            body_captures = body_result ? body_result.last : captures
            body_captures = body_captures.dup
            body_captures.delete(:__match_start)
            body_captures = captures if captureless_absence_body?(node.body)
            body_captures = adjust_nested_repeat_capture(node.body, body_captures, body_result&.first, cursor)
            body_captures = filter_nested_absence_captures(node.body, body_captures)
            body_captures = filter_absence_capture_scope(node.body, body_captures)
            return quantified.downto(0).map { |length| [length, body_captures] }
          end

          cursor.upto(characters.length) do |position|
            results = node_results(node.body, characters, position, captures, flags)
            next if results.empty?

            length, inner_captures = results.find { |candidate, _state| candidate.positive? } || results.first
            inner_captures = inner_captures.dup
            internal_start = inner_captures.delete(:__match_start)
            internal_end = inner_captures.delete(:__match_end)
            internal_prefix = inner_captures.delete(:__match_prefix)
            internal_prefix_value = inner_captures.delete(:__match_prefix_value)
            internal_probe = inner_captures.delete(:__match_probe)
            internal_alternative = inner_captures.delete(:__match_alternative)
            inner_captures = captures if captureless_absence_body?(node.body)
            inner_captures = adjust_nested_repeat_capture(node.body, inner_captures, length, position)
            inner_captures = filter_nested_absence_captures(node.body, inner_captures)
            inner_captures = filter_absence_capture_scope(node.body, inner_captures)
            quantified_length = quantified_absence_length(node.body, characters, position)
            match_position = internal_start || position
            maximum = if quantified_length
                        match_position - cursor + quantified_length
                      elsif length.zero? && match_position > cursor
                        characters.length - cursor
                      elsif internal_alternative && internal_prefix.nil?
                        internal_start - cursor
                      elsif internal_end
                        effective_length = internal_end - internal_start
                        if internal_prefix_value && internal_probe && internal_prefix_value == internal_probe
                          internal_end - cursor - 1
                        elsif internal_prefix&.zero? || effective_length.zero?
                          characters.length - cursor
                        else
                          internal_end - cursor - 1
                        end
                      elsif internal_start && internal_start > position + length
                        internal_start - cursor - 1
                      else
                        match_position - cursor + length - 1
                      end
            maximum = [maximum, 0].max
            return maximum.downto(0).map { |candidate| [candidate, inner_captures] }
          end
          maximum = characters.length - cursor
          maximum.downto(0).map { |length| [length, captures] }
        end

        def zero_width_absence_results(body, characters, cursor, captures, flags)
          positions = []
          has_consuming_match = false
          cursor.upto(characters.length) do |position|
            results = node_results(body, characters, position, captures, flags)
            positions << position if results.any? do |length, state|
              length.zero? && (state[:__match_start] || position) == position
            end
            has_consuming_match ||= results.any? { |length, _state| length.positive? }
          end
          return if positions.empty? || has_consuming_match

          start = cursor.upto(characters.length).find do |position|
            node_results(body, characters, position, captures, flags).none? do |length, state|
              length.zero? && (state[:__match_start] || position) == position
            end
          end || characters.length
          finish = if start == characters.length
                     start
                   else
                     (start + 1).upto(characters.length).find do |position|
                       node_results(body, characters, position, captures, flags).any? do |length, state|
                         length.zero? && (state[:__match_start] || position) == position
                       end
                     end || characters.length
                   end
          state = captures.dup
          if start != cursor
            state[:__match_start] = start
            state[:__match_end] = finish
            state[:__match_probe] = characters[start - 1] if start.positive?
          end
          [[finish - start, state]]
        end

        def zero_width_star_absence?(body, characters, cursor)
          sequence = if body.is_a?(Onibi::AST::Sequence) || body.is_a?(SemanticBytecode::Sequence)
                       body.parts
                     else
                       [body]
                     end
          return false unless sequence.length == 1

          quantifier = sequence.first
          return false unless quantifier.is_a?(Onibi::AST::Quantifier) ||
                              quantifier.is_a?(SemanticBytecode::Quantifier)
          return false unless quantifier.kind == :* && quantifier.maximum.nil?

          literal = literal_value(quantifier.expression)
          literal && !literal.empty? && cursor < characters.length &&
            characters[cursor, literal.length].join != literal
        end

        def captureless_absence_body?(body)
          parts = if body.is_a?(Onibi::AST::Sequence) || body.is_a?(SemanticBytecode::Sequence)
                    body.parts
                  else
                    [body]
                  end
          parts.length == 1 &&
            (parts.first.is_a?(Onibi::AST::Quantifier) || parts.first.is_a?(SemanticBytecode::Quantifier))
        end

        def adjust_nested_repeat_capture(body, captures, length, cursor)
          return captures unless length

          parts = body.is_a?(Onibi::AST::Sequence) || body.is_a?(SemanticBytecode::Sequence) ? body.parts : [body]
          outer = parts.first
          return captures unless parts.length == 1 &&
                                 (outer.is_a?(Onibi::AST::Group) || outer.is_a?(SemanticBytecode::Group))

          nested = outer.body
          nested_parts = nested.is_a?(Onibi::AST::Sequence) || nested.is_a?(SemanticBytecode::Sequence) ? nested.parts : [nested]
          quantifier = nested_parts.first
          return captures unless nested_parts.length == 1 &&
                                 (quantifier.is_a?(Onibi::AST::Quantifier) || quantifier.is_a?(SemanticBytecode::Quantifier))

          if length.zero?
            adjusted = captures.dup
            adjusted.delete(outer.number)
            return adjusted
          end

          unless quantifier.kind == :+
            adjusted = captures.dup
            adjusted.delete(outer.number) if length.zero? || quantifier.kind != :"?"
            return adjusted
          end

          variable_units = variable_alternation_units(quantifier.expression)
          if variable_units
            return captures if length <= 2

            adjusted = captures.dup
            width = length % 3
            if width.zero?
              adjusted.delete(outer.number)
            else
              start = cursor + (length / 2)
              adjusted[outer.number] = [start, start + width]
            end
            return adjusted
          end

          unit = literal_value(quantifier.expression)
          unit ||= alternation_unit(quantifier.expression)
          return captures unless unit && quantifier.kind == :+ && !unit.empty?

          repetitions = length / unit.length
          adjusted = captures.dup
          if unit.length == 1
            if repetitions >= 3
              width = [repetitions - 2, 2].min
              start = cursor + ((repetitions - 1) / 2)
              adjusted[outer.number] = [start, start + width]
            end
          elsif repetitions.even?
            adjusted.delete(outer.number)
          else
            start = cursor + ((repetitions - 1) / 2) * unit.length
            adjusted[outer.number] = [start, start + unit.length]
          end
          adjusted
        end

        def filter_nested_absence_captures(body, captures)
          parts = body.is_a?(Onibi::AST::Sequence) || body.is_a?(SemanticBytecode::Sequence) ? body.parts : [body]
          outer = parts.first
          return captures unless parts.length == 1 &&
                                 (outer.is_a?(Onibi::AST::Group) || outer.is_a?(SemanticBytecode::Group))

          nested = outer.body
          nested_parts = nested.is_a?(Onibi::AST::Sequence) || nested.is_a?(SemanticBytecode::Sequence) ? nested.parts : [nested]
          quantifier = nested_parts.first
          return captures unless nested_parts.length == 1 &&
                                 (quantifier.is_a?(Onibi::AST::Quantifier) || quantifier.is_a?(SemanticBytecode::Quantifier))

          expression = quantifier.expression
          return captures unless expression.is_a?(Onibi::AST::Group) || expression.is_a?(SemanticBytecode::Group)

          captures.select { |key, _value| key == outer.number }
        end

        def filter_absence_capture_scope(body, captures)
          scope = body
          loop do
            if (scope.is_a?(Onibi::AST::Group) || scope.is_a?(SemanticBytecode::Group)) && !scope.capture
              scope = scope.body
            elsif scope.is_a?(Onibi::AST::Sequence) || scope.is_a?(SemanticBytecode::Sequence)
              only = scope.parts.one? && scope.parts.first
              break unless only.is_a?(Onibi::AST::Group) || only.is_a?(SemanticBytecode::Group)
              break if only.capture

              scope = only.body
            else
              break
            end
          end
          parts = scope.is_a?(Onibi::AST::Sequence) || scope.is_a?(SemanticBytecode::Sequence) ? scope.parts : [scope]
          direct_group = parts.any? do |part|
            (part.is_a?(Onibi::AST::Group) || part.is_a?(SemanticBytecode::Group)) && part.capture
          end
          direct_group ? captures : {}
        end

        def generic_absence_length(node, characters, cursor, flags)
          quantified = quantified_absence_length(node.body, characters, cursor)
          return quantified if quantified

          cursor.upto(characters.length) do |position|
            results = node_results(node.body, characters, position, {}, flags)
            next if results.empty?

            quantified_length = quantified_absence_length(node.body, characters, position)
            return quantified_length + position - cursor if quantified_length

            return [position - cursor + results.first[0] - 1, 0].max
          end
          characters.length - cursor
        end

        def quantified_absence_length(body, characters, cursor)
          sequence = if body.is_a?(Onibi::AST::Sequence) || body.is_a?(SemanticBytecode::Sequence)
                       body.parts
                     else
                       [body]
                     end
          return unless sequence.length == 1

          if sequence.first.is_a?(Onibi::AST::Group) || sequence.first.is_a?(SemanticBytecode::Group)
            nested = sequence.first.body
            nested_parts = (nested.parts if nested.is_a?(Onibi::AST::Sequence) || nested.is_a?(SemanticBytecode::Sequence))
            return quantified_absence_length(nested, characters, cursor) if nested_parts&.length == 1
          end

          quantifier = sequence.first
          return unless quantifier.is_a?(Onibi::AST::Quantifier) || quantifier.is_a?(SemanticBytecode::Quantifier)
          return unless quantifier.maximum.nil?
          return unless %i[+ *].include?(quantifier.kind) || quantifier.minimum.to_i >= 2

          literal = literal_value(quantifier.expression)
          variable_units = variable_alternation_units(quantifier.expression)
          if variable_units
            repetitions = 0
            position = cursor
            lengths = []
            while position < characters.length
              value = variable_units.sort_by(&:length).reverse.find do |candidate|
                characters[position, candidate.length].join == candidate
              end
              break unless value

              lengths << value.length
              repetitions += 1
              position += value.length
            end
            return if repetitions < quantifier.minimum

            if quantifier.minimum.to_i >= 2
              if variable_units.first.length < variable_units.map(&:length).max &&
                 lengths.include?(variable_units.map(&:length).max)
                return variable_units.map(&:length).max
              end

              return lengths.all? { |length| length == 1 } ? (position - cursor + quantifier.minimum - 1) / 2 : (position - cursor) - ((position - cursor) / 3)
            end

            return ((position - cursor) * 2) / 3 if quantifier.kind == :+
          end
          unit = literal || alternation_unit(quantifier.expression)
          run = 0
          position = cursor
          if unit && !unit.empty?
            while position < characters.length
              matched = if literal
                          characters[position, unit.length].join == unit
                        else
                          node_results(quantifier.expression, characters, position, {}, {}).any? do |length, _captures|
                            length == unit.length
                          end
                        end
              break unless matched

              run += unit.length
              position += unit.length
            end
          elsif quantifier.expression.is_a?(Onibi::AST::CharacterClass) ||
                quantifier.expression.is_a?(SemanticBytecode::CharacterClass)
            while position < characters.length && class_match_lengths(quantifier.expression, characters, position, {}).include?(1)
              run += 1
              position += 1
            end
          else
            return
          end
          return if run.zero?

          if unit && unit.length > 1
            units = run / unit.length
            return if units < quantifier.minimum
            return units + (units.even? ? 1 : 2) if quantifier.minimum.to_i >= 2

            return units.even? ? units + 1 : units
          end

          if quantifier.minimum.to_i >= 2
            return if run < quantifier.minimum

            (run + quantifier.minimum - 1) / 2
          else
            run / 2
          end
        end

        def alternation_unit(node)
          branches = case node
                     when Onibi::AST::Alternation, SemanticBytecode::Alternation
                       node.branches
                     when Onibi::AST::Group, SemanticBytecode::Group
                       return alternation_unit(node.body)
                     when Onibi::AST::Sequence, SemanticBytecode::Sequence
                       return alternation_unit(node.parts.first) if node.parts.length == 1
                     end
          return unless branches && !branches.empty?

          values = branches.map { |branch| literal_value(branch) }
          return unless values.all? && values.map(&:length).uniq.one?

          values.first
        end

        def variable_alternation_units(node)
          body = if node.is_a?(Onibi::AST::Group) || node.is_a?(SemanticBytecode::Group)
                   node.body
                 elsif node.is_a?(Onibi::AST::Sequence) || node.is_a?(SemanticBytecode::Sequence)
                   node.parts.length == 1 ? node.parts.first : node
                 else
                   node
                 end
          branches = (body.branches if body.is_a?(Onibi::AST::Alternation) || body.is_a?(SemanticBytecode::Alternation))
          return unless branches

          values = branches.map { |branch| literal_value(branch) }
          return unless values.all? && values.map(&:length).uniq.length > 1

          values
        end

        def class_match_lengths(node, characters, cursor, flags)
          return [] unless cursor < characters.length

          lengths = []
          character = characters[cursor]
          lengths << 1 if Onibi::ClassPredicates.matches?(node.value, character, ignorecase: flags[:ignorecase])
          casefold_source = flags[:ignorecase] && !node.value.start_with?("^") &&
                            !node.value.include?("[") && !node.value.include?(":") &&
                            !node.value.include?("&&") && !node.value.include?("\\")
          lengths << 1 if casefold_source && node.value.each_char.any? do |candidate|
            casefold_equal?(candidate, character)
          end && !lengths.include?(1)
          lengths << 2 if casefold_source && node.value.each_char.any? do |candidate|
            casefold_equal?(candidate, characters[cursor, 2].to_a.join)
          end
          lengths
        rescue RangeError, ArgumentError
          lengths
        end

        def boundary_word?(character)
          return Onibi::CharacterPredicates.word?(character) if character.encoding == Encoding::ASCII_8BIT

          Onibi::UnicodeProperties.word?(unicode_character(character))
        end

        def assertion_length(assertion, characters, cursor, flags = {})
          if %i[positive_lookbehind negative_lookbehind].include?(assertion.kind)
            guard = literal_value(assertion.body)
            maximum = guard ? [guard.length * 2, 2].max : 2
            matched = (1..[cursor, maximum].min).any? do |width|
              sequence_length(assertion.body, characters, cursor - width, flags) == width
            end
            return matched == %i[positive_lookbehind].include?(assertion.kind) ? 0 : nil
          end

          guard = literal_value(assertion.body)
          matched = if guard
                      if %i[positive_lookbehind negative_lookbehind].include?(assertion.kind)
                        characters[[cursor - guard.length, 0].max, guard.length].to_a.join == guard && cursor >= guard.length
                      else
                        characters[cursor, guard.length].to_a.join == guard
                      end
                    elsif %i[positive_lookbehind negative_lookbehind].include?(assertion.kind)
                      width = sequence_length(assertion.body, characters, 0)
                      width && cursor >= width && sequence_length(assertion.body, characters, cursor - width) == width
                    else
                      sequence_length(assertion.body, characters, cursor)
                    end
          if matched.nil?
            return 0 if %i[negative negative_lookbehind].include?(assertion.kind)

            return nil
          end

          matched = if %i[positive positive_lookahead positive_lookbehind].include?(assertion.kind)
                      matched
                    else
                      !matched
                    end
          matched ? 0 : nil
        end

        def anchor_length(anchor, characters, cursor)
          valid = case anchor.kind
                  when :anchor_start
                    cursor.zero? || (cursor.positive? && cursor < characters.length && characters[cursor - 1] == "\n")
                  when :anchor_absolute_start then cursor.zero?
                  when :anchor_end then cursor == characters.length || characters[cursor] == "\n"
                  when :anchor_absolute_end then cursor == characters.length
                  when :anchor_before_final_newline
                    cursor == characters.length || (characters[cursor] == "\n" && cursor + 1 == characters.length)
                  else false
                  end
          valid ? 0 : nil
        end

        def literal_value(node)
          case node
          when Onibi::AST::Literal, SemanticBytecode::Literal then node.value
          when Onibi::AST::Group, SemanticBytecode::Group then literal_value(node.body)
          when Onibi::AST::Sequence, SemanticBytecode::Sequence
            node.parts.map { |part| literal_value(part) }.then { |values| values.all? ? values.join : nil }
          end
        end

        def casefold_equal?(left, right)
          left.upcase.downcase == right.upcase.downcase || left.downcase == right.downcase
        end

        def property_matches?(name, character, ignorecase)
          return true if Onibi::UnicodeProperties.matches?(name, character)
          return false unless ignorecase && %w[Lower Upper].include?(name)

          opposite = name == "Lower" ? "Upper" : "Lower"
          Onibi::UnicodeProperties.matches?(opposite, character)
        end

        def unicode_character(character)
          character.encoding == Encoding::UTF_8 ? character : character.encode(Encoding::UTF_8)
        rescue EncodingError
          character
        end
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
