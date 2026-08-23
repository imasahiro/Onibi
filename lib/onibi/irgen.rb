# frozen_string_literal: true

module Onibi
  module IRGen
    module YARVIR
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
          @dfa = program.automaton
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
          return nil unless @dfa.is_a?(Onibi::Automata::DFA)

          characters = if input.encoding == Encoding::ASCII_8BIT
                         input.bytes.map { |byte| byte.chr(Encoding::ASCII_8BIT) }
                       else
                         input.codepoints.map { |codepoint| codepoint.chr(input.encoding) }
                       end
          @characters = characters
          first = [start_position, 0].max
          first.upto(characters.length) do |start|
            result = walk(@dfa.start_state.id, characters, start, {}, start, @program.flags)
            return result if result
          end
          nil
        end

        def walk(state, characters, cursor, captures, start, flags)
          return [start, cursor, captures] if accepting?(state)

          transitions_for(state).each do |label, target|
            transition_results(label, characters, cursor, captures, flags).each do |length, inner_captures|
              next_captures = captures.dup
              next_captures.merge!(inner_captures)
              captures_for(label, cursor, length, next_captures)
              next_start = if label[0] == :match_escape && label[1].kind == :match_reset
                             cursor
                           else
                             start
                           end
              result = walk(target, characters, cursor + length, next_captures, next_start, flags)
              return result if result
            end
          end
          nil
        end

        def transition_results(label, characters, cursor, captures, flags = {})
          opcode, operand = label
          case opcode
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
          else
            transition_lengths(label, characters, cursor, captures, flags).map { |length| [length, {}] }
          end
        end

        def assertion_results(assertion, characters, cursor, captures, flags = {})
          if %i[positive positive_lookahead].include?(assertion.kind)
            return node_results(assertion.body, characters, cursor, captures, flags).first(1).map { |_length, inner| [0, inner] }
          end

          if %i[negative negative_lookahead].include?(assertion.kind)
            matched = node_results(assertion.body, characters, cursor, captures, flags).any?
            return matched ? [] : [[0, captures]]
          end

          length = assertion_length(assertion, characters, cursor)
          length ? [[0, captures]] : []
        end

        def node_results(node, characters, cursor, captures, flags = {})
          case node
          when Onibi::AST::Sequence
            states = [[0, captures]]
            node.parts.each do |part|
              states = states.flat_map do |consumed, state_captures|
                node_results(part, characters, cursor + consumed, state_captures, flags).map do |length, inner|
                  [consumed + length, inner]
                end
              end
              return [] if states.empty?
            end
            states
          when Onibi::AST::Alternation
            node.branches.flat_map { |branch| node_results(branch, characters, cursor, captures, flags) }
          when Onibi::AST::Group
            node_results(node.body, characters, cursor, captures, flags).map do |length, inner|
              next_captures = inner.dup
              if node.capture
                next_captures[node.number] = [cursor, cursor + length]
                next_captures[node.name] = [cursor, cursor + length] if node.name
              end
              [length, next_captures]
            end
          when Onibi::AST::Quantifier
            quantifier_results(node, characters, cursor, captures, flags)
          when Onibi::AST::OptionGroup
            node_results(node.body, characters, cursor, captures,
                         flags.merge(ignorecase: node.ignorecase, multiline: node.multiline))
          when Onibi::AST::Assertion
            assertion_results(node, characters, cursor, captures, flags)
          when Onibi::AST::SubexpressionCall
            body = @subexpressions[node.identifier]
            return [] unless body
            return [] if (@subexpression_depth ||= 0) > 32

            @subexpression_depth += 1
            results = node_results(body, characters, cursor, captures, flags)
            @subexpression_depth -= 1
            results
          else
            length = transition_length([operation_for(node), node], characters, cursor, flags, captures)
            length ? [[length, captures]] : []
          end
        end

        def quantifier_results(quantifier, characters, cursor, captures, flags = {})
          limit = quantifier.maximum || characters.length - cursor
          frontier = [[0, captures]]
          accepted = quantifier.minimum.zero? ? frontier.dup : []
          count = 0
          while count < limit
            next_frontier = frontier.flat_map do |consumed, state_captures|
              node_results(quantifier.expression, characters, cursor + consumed, state_captures, flags).filter_map do |length, inner|
                next if length.zero?

                [consumed + length, inner]
              end
            end
            break if next_frontier.empty?

            count += 1
            frontier = next_frontier
            accepted.concat(frontier) if count >= quantifier.minimum
          end
          return [] if count < quantifier.minimum

          accepted = accepted.uniq { |length, state| [length, state] }
          return [accepted.max_by(&:first)] if quantifier.mode == :possessive

          quantifier.mode == :lazy ? accepted.sort_by(&:first) : accepted.sort_by(&:first).reverse
        end

        def transition_lengths(label, characters, cursor, captures, flags = {})
          opcode, operand = label
          return quantifier_lengths(operand, characters, cursor) if opcode == :match_quantifier

          length = transition_length(label, characters, cursor, flags, captures)
          length ? [length] : []
        end

        def transitions_for(state)
          @dfa.transitions.filter_map do |(source, label), target|
            [label, target] if source == state
          end
        end

        def accepting?(state)
          @dfa.states.any? { |candidate| candidate.id == state && candidate.accepting }
        end

        def transition_length(label, characters, cursor, flags = {}, captures = {})
          opcode, operand = label
          case opcode
          when :match_literal
            value = operand.value.each_char.to_a
            matched = flags[:ignorecase] ? value.join.casecmp?(characters[cursor, value.length].to_a.join) : characters[cursor, value.length] == value
            matched ? value.length : nil
          when :match_class
            cursor < characters.length && Onibi::ClassPredicates.matches?(operand.value, characters[cursor], ignorecase: flags[:ignorecase]) ? 1 : nil
          when :match_any
            cursor < characters.length && (flags[:multiline] || operand.value != "." || characters[cursor] != "\n") ? 1 : nil
          when :match_escape
            case operand.kind
            when :word_boundary, :not_word_boundary
              left = cursor.positive? && Onibi::CharacterPredicates.escape_matches?(:word, characters[cursor - 1])
              right = cursor < characters.length && Onibi::CharacterPredicates.escape_matches?(:word, characters[cursor])
              boundary = left != right
              boundary = !boundary if operand.kind == :not_word_boundary
              boundary ? 0 : nil
            when :linebreak
              return nil unless cursor < characters.length && Onibi::CharacterPredicates.linebreak?(characters[cursor])

              characters[cursor] == "\r" && characters[cursor + 1] == "\n" ? 2 : 1
            when :match_reset
              0
            else
              cursor < characters.length && Onibi::CharacterPredicates.escape_matches?(operand.kind, characters[cursor]) ? 1 : nil
            end
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
          when :match_backreference
            backreference_length(operand, characters, cursor, captures)
          when :match_conditional
            conditional_length(operand, characters, cursor, captures)
          when :match_atomic_group
            sequence_length(operand.body, characters, cursor)
          when :match_option_group
            option_group_length(operand, characters, cursor)
          when :match_absence
            absence_length(operand, characters, cursor)
          when :match_assertion
            assertion_length(operand, characters, cursor)
          when :test_anchor
            anchor_length(operand, characters, cursor)
          end
        end

        def quantifier_length(quantifier, characters, cursor, flags = {})
          if quantifier.expression.is_a?(Onibi::AST::Group)
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
          if quantifier.expression.is_a?(Onibi::AST::Group)
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

        def captures_for(label, cursor, length, captures)
          opcode, operand = label
          if opcode == :match_absence
            capture_absence(operand.body, cursor, length, captures)
            return
          end
          if opcode == :match_quantifier && operand.expression.is_a?(Onibi::AST::Group)
            group = operand.expression
            return unless group.capture && length.positive?

            captures[group.number] ||= [cursor, cursor + length]
            captures[group.name] ||= [cursor, cursor + length] if group.name
            return
          end
          return unless opcode == :match_group && operand.capture

          captures[operand.number] = [cursor, cursor + length]
          captures[operand.name] = [cursor, cursor + length] if operand.name
          capture_nested_groups(operand.body, cursor, captures)
        end

        def capture_nested_groups(node, cursor, captures)
          position = cursor
          parts = node.is_a?(Onibi::AST::Sequence) ? node.parts : [node]
          parts.each do |part|
            if part.is_a?(Onibi::AST::Group)
              value = literal_value(part.body)
              if part.capture && value
                captures[part.number] = [position, position + value.length]
                captures[part.name] = [position, position + value.length] if part.name
              end
              capture_nested_groups(part.body, position, captures)
            else
              value = literal_value(part)
            end
            position += value.length if value
          end
        end

        def capture_absence(node, cursor, _length, captures)
          return unless node.is_a?(Onibi::AST::Sequence)

          group = node.parts.find { |part| part.is_a?(Onibi::AST::Group) && part.capture }
          return unless group

          value = literal_value(group.body)
          return unless value

          relative_start = @characters[cursor..]&.join.to_s.index(value)
          return unless relative_start

          delimiter_start = cursor + relative_start
          captures[group.number] = [delimiter_start, delimiter_start + value.length]
          captures[group.name] = [delimiter_start, delimiter_start + value.length] if group.name
        end

        def backreference_length(reference, characters, cursor, captures)
          span = captures[reference.identifier]
          return nil unless span

          value = characters[span[0]...span[1]]
          characters[cursor, value.length] == value ? value.length : nil
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
          when Onibi::AST::Literal
            flags[:ignorecase] ? expression.value.casecmp?(character) : expression.value == character
          when Onibi::AST::CharacterClass then Onibi::ClassPredicates.matches?(expression.value, character)
          when Onibi::AST::Escape then Onibi::CharacterPredicates.escape_matches?(expression.kind, character)
          when Onibi::AST::Property then Onibi::UnicodeProperties.matches?(expression.name, character)
          when Onibi::AST::Any then flags[:multiline] || expression.value != "." || character != "\n"
          else false
          end
        end

        def sequence_length(node, characters, cursor, flags = {})
          parts = node.is_a?(Onibi::AST::Sequence) ? node.parts : [node]
          position = cursor
          parts.each do |part|
            length = case part
                     when Onibi::AST::Quantifier then quantifier_length(part, characters, position, flags)
                     when Onibi::AST::Group then sequence_length(part.body, characters, position, flags)
                     else transition_length([operation_for(part), part], characters, position, flags)
                     end
            return nil unless length

            position += length
          end
          position - cursor
        end

        def option_group_length(group, characters, cursor)
          sequence_length(group.body, characters, cursor,
                          ignorecase: group.ignorecase, multiline: group.multiline)
        end

        def operation_for(node)
          case node
          when Onibi::AST::Literal then :match_literal
          when Onibi::AST::CharacterClass then :match_class
          when Onibi::AST::Any then :match_any
          when Onibi::AST::Escape then :match_escape
          when Onibi::AST::Property then :match_property
          when Onibi::AST::Backreference then :match_backreference
          when Onibi::AST::Conditional then :match_conditional
          when Onibi::AST::Absence then :match_absence
          when Onibi::AST::Assertion then :match_assertion
          when Onibi::AST::Anchor then :test_anchor
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

        def assertion_length(assertion, characters, cursor)
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
          return nil if matched.nil?

          matched = if %i[positive positive_lookahead positive_lookbehind].include?(assertion.kind)
                      matched
                    else
                      !matched
                    end
          matched ? 0 : nil
        end

        def anchor_length(anchor, characters, cursor)
          valid = case anchor.kind
                  when :anchor_start then cursor.zero? || (cursor.positive? && characters[cursor - 1] == "\n")
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
          when Onibi::AST::Literal then node.value
          when Onibi::AST::Group then literal_value(node.body)
          when Onibi::AST::Sequence
            node.parts.map { |part| literal_value(part) }.then { |values| values.all? ? values.join : nil }
          end
        end
      end

      def execute(program, input, start_position = 0)
        Executor.new(program).match(input, start_position)
      end

      def execute_with_captures(program, input, start_position = 0)
        Executor.new(program).match_with_captures(input, start_position)
      end
    end
  end
end
