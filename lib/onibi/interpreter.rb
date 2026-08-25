# frozen_string_literal: true

module Onibi
  module Interpreter
    # SemanticBytecode is the compiler-owned operand model.
    SemanticBytecode = Onibi::IRGen::YARVIR::SemanticBytecode

    # Runtime state for the Onigmo-style absence loop.
    # `absent_end` is exclusive before a probe and becomes body_end - 1 after
    # a body result. `probe_position` advances one character per iteration.
    # `possible_points` stores [cursor, captures] checkpoints.
    # `body_checkpoints` stores ordered body results for each point.
    # `capture_checkpoints` stores
    # [probe_position, body_length, captures, discard_capture, ambiguous].
    # The interpreter restores this state after a failed suffix, like
    # OP_ABSENT_END popping to its absent frame.
    AbsentFrame = Struct.new(
      :absent_start,
      :absent_end,
      :probe_position,
      :possible_points,
      :body_checkpoints,
      :capture_checkpoints,
      keyword_init: true
    )

    # Formal VM contract:
    # DFA: start(state), match(label), jump(state), accept(state).
    # TNFA: nfa_start(states), nfa_match([from, to, [opcode, operand]]),
    # nfa_accept(states). Match consumes input and advances the cursor.
    # Jump and start change control state only. Accept returns the match.
    # Semantic operands return [consumed_length, next_captures]. The operand
    # stack is this result list. Local state is captures plus internal keys.
    BYTECODE_SPEC = {
      dfa: {
        start: { operand: :state_id, stack: :unchanged, local: :state_selected },
        match: { operand: :transition_label, stack: :push_result, local: :consume_and_merge },
        jump: { operand: :state_id, stack: :unchanged, local: :state_selected },
        accept: { operand: :state_id, stack: :halt, local: :return_match }
      },
      tnfa: {
        nfa_start: { operand: :state_ids, stack: :unchanged, local: :active_states },
        nfa_match: { operand: :edge, stack: :push_result, local: :consume_and_merge },
        nfa_accept: { operand: :state_ids, stack: :halt, local: :return_match }
      },
      semantic: {
        match_literal: { operand: :literal, stack: :push_result, local: :consume_and_merge },
        match_class: { operand: :character_class, stack: :push_result, local: :consume_and_merge },
        match_escape: { operand: :escape, stack: :push_result, local: :consume_and_merge },
        match_property: { operand: :property, stack: :push_result, local: :consume_and_merge },
        match_any: { operand: :dot, stack: :push_result, local: :consume_and_merge },
        match_assertion: { operand: :assertion, stack: :push_result, local: :zero_width },
        test_anchor: { operand: :anchor, stack: :push_result, local: :zero_width },
        match_absence: {
          operand: :absence,
          stack: :push_result,
          local: :absent_frame,
          language: :complement_of_wrapped_body,
          wrapped_language: ".* body .*",
          preserves: :ordered_body_candidates,
          capture_checkpoint: :repeat_frame_state,
          transition: :probe_with_bounded_end
        },
        match_group: { operand: :group, stack: :push_result, local: :capture_scope },
        match_quantifier: { operand: :quantifier, stack: :push_result, local: :repeat_and_merge },
        match_atomic_group: { operand: :atomic_group, stack: :push_result, local: :atomic_scope },
        match_backreference: { operand: :capture_number, stack: :push_result, local: :consume_and_merge },
        match_conditional: { operand: :conditional, stack: :push_result, local: :branch },
        match_subexpression_call: { operand: :capture_number, stack: :push_result, local: :call },
        match_option_group: { operand: :option_group, stack: :push_result, local: :scoped_flags }
      }
    }.freeze

    class Executor
      def initialize(program)
        @program = program
        @automaton = program.automaton
        @subexpressions = program.flags[:subexpressions] || {}
        @retry_shifted_absence = shifted_absence_suffix?(program.flags[:semantic_root])
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
        input_encoding = String.instance_method(:encoding).bind_call(input)
        input_ascii_only = String.instance_method(:ascii_only?).bind_call(input)
        byte_input = input_encoding == Encoding::ASCII_8BIT ||
                     (@program.flags[:binary_escape] && input_encoding == Encoding::ISO_8859_1)
        input_view = Onibi::InputView.new(input, byte_mode: byte_input)
        characters = input_view.characters
        @input_view = input_view
        @characters = characters
        @steps = 0
        # Character classes use the input encoding when an ASCII pattern can
        # match several encodings. MRI applies POSIX rules to this encoding.
        runtime_flags = @program.flags.merge(
          encoding: input_encoding,
          full_casefold: @program.flags[:full_casefold] ||
                         (input_encoding == Encoding::UTF_8 && !input_ascii_only)
        )
        first = [start_position, 0].max
        @match_start = first
        first.upto(characters.length) do |start|
          result = if (root = @program.flags[:semantic_root])
                     node_results(root, characters, start, {}, runtime_flags).first&.then do |length, captures|
                       match_start = captures.delete(:__match_start) || start
                       hidden_captures = captures.delete(:__absence_captures)
                       captures.merge!(hidden_captures) if hidden_captures
                       match_prefix = captures.key?(:__match_prefix)
                       match_reset = captures.delete(:__match_reset)
                       captures.delete(:__match_end)
                       captures.delete(:__match_probe)
                       captures.delete(:__match_prefix)
                       captures.delete(:__match_prefix_value)
                       captures.delete(:__match_alternative)
                       captures.delete(:__match_alternative_index)
                       captures.delete(:__zero_absence)
                       captures.delete(:__match_prefix_zero_absence)
                       captures.delete(:__end_zero_width)
                       finish = if match_reset
                                  start + length
                                elsif match_start > start && match_prefix
                                  # The sequence length includes the prefix
                                  # consumed before the absence probe moved the
                                  # reported match start forward.
                                  start + length
                                else
                                  match_start + length
                                end
                       [match_start, finish, captures]
                     end
                   elsif @automaton.is_a?(Onibi::Automata::DFA)
                     walk_dfa(@automaton.start_state.id, characters, start, {}, start, runtime_flags)
                   elsif @automaton.is_a?(Onibi::Automata::GlushkovTNFA)
                     walk_tnfa(:start, characters, start, {}, start, runtime_flags)
                   end
          next if result && @retry_shifted_absence && result.first > start
          return result if result
        end
        nil
      end

      def shifted_absence_suffix?(node)
        case node
        when SemanticBytecode::Sequence
          node.parts.each_with_index.any? do |part, index|
            index < node.parts.length - 1 && part.is_a?(SemanticBytecode::Absence)
          end || node.parts.any? { |part| shifted_absence_suffix?(part) }
        when SemanticBytecode::Group, SemanticBytecode::OptionGroup,
             SemanticBytecode::AtomicGroup, SemanticBytecode::Quantifier,
             SemanticBytecode::Absence
          child = node.respond_to?(:body) ? node.body : node.expression
          shifted_absence_suffix?(child)
        when SemanticBytecode::Alternation
          node.branches.any? { |branch| shifted_absence_suffix?(branch) }
        else
          false
        end
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
          # The absence operand returns both its bounded complement length and
          # the capture state restored by the last body checkpoint. Do not
          # reduce this to lengths: the bytecode edge carries semantic state.
          absence_results(operand, characters, cursor, captures, flags)
        when :match_class
          class_match_lengths(operand, characters, cursor, flags).map { |length| [length, {}] }
        when :match_property
          property_match_lengths(operand, characters, cursor, flags).map { |length| [length, {}] }
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
          return mark_end_zero_width(lookbehind_results(assertion, characters, cursor, captures, flags),
                                     characters, cursor, flags)
        end

        if assertion.kind == :negative_lookbehind
          matched = lookbehind_results(assertion, characters, cursor, captures, flags).any?
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

      def lookbehind_results(assertion, characters, cursor, captures, flags)
        widths = assertion.widths || (0..cursor).to_a
        if flags[:ignorecase]
          folded_widths = casefold_widths(assertion.body)
          widths = folded_widths unless folded_widths.empty?
        end
        lookbehind_flags = flags.merge(lookbehind_casefold: true)
        widths.select { |width| width <= cursor }.sort.reverse_each do |width|
          results = node_results(assertion.body, characters, cursor - width, captures, lookbehind_flags)
          matching = results.select { |length, _inner| length == width }
          return matching.map { |_length, inner| [0, inner] } unless matching.empty?
        end
        []
      end

      def casefold_widths(node)
        case node
        when SemanticBytecode::Literal
          source_length = node.value.length
          folded_length = (node.casefold || node.value).length
          folded_length > source_length ? [folded_length] : [source_length]
        when SemanticBytecode::CharacterClass
          return [1] if node.value.match?(/[\\\[\]:&^]/)

          node.value.each_char.map { |character| character.downcase(:fold).length }.uniq
        when SemanticBytecode::Sequence
          node.parts.reduce([0]) do |widths, part|
            widths.product(casefold_widths(part)).map { |left, right| left + right }.uniq
          end
        when SemanticBytecode::Alternation
          node.branches.flat_map { |branch| casefold_widths(branch) }.uniq
        when SemanticBytecode::Group, SemanticBytecode::OptionGroup,
             SemanticBytecode::AtomicGroup, SemanticBytecode::Assertion
          casefold_widths(node.body)
        when SemanticBytecode::Quantifier
          body_widths = casefold_widths(node.expression)
          maximum = node.maximum || node.minimum
          (node.minimum..maximum).flat_map do |count|
            body_widths.repeated_combination(count).map(&:sum)
          end.uniq
        else
          []
        end
      end

      def node_results(node, characters, cursor, captures, flags = {})
        @steps += 1
        return [] if @steps > 2_000_000

        case node
        when SemanticBytecode::Sequence
          if flags[:ignorecase] && node.parts.all? { |part| part.is_a?(SemanticBytecode::Literal) }
            value = node.parts.map(&:value).join
            first_expands = node.parts.first &&
                            node.parts.first.value.downcase(:fold).length > node.parts.first.value.length
            has_mark = value.each_char.any? { |character| Onibi::UnicodeProperties.mark?(character) }
            reverse_fold = reverse_casefold_sequence?(value)
            folded_value = node.parts.map { |part| part.casefold || part.value }.join
            fold_boundary_sensitive = node.parts.each_cons(2).any? do |left, right|
              left.casefold && left.casefold.length == left.value.length &&
                right.casefold && right.casefold.length > right.value.length
            end
            if !value.empty? && !fold_boundary_sensitive && (value.ascii_only? || first_expands ||
              has_mark || reverse_fold || folded_value != value)
              folded_length = casefold_lengths(value, characters, cursor,
                                               folded: folded_value,
                                               expanded_only: flags[:lookbehind_casefold]).first
              return folded_length ? [[folded_length, captures.dup]] : []
            end
          end

          class_repetition = flags[:ignorecase] && flags[:casefold_repetition] &&
                             node.parts.length > 1 &&
                             node.parts.all? { |part| part.is_a?(SemanticBytecode::CharacterClass) } &&
                             node.parts.none? { |part| part.value.start_with?("^") } &&
                             (node.parts.all? { |part| part.casefolds.empty? } ||
                              node.parts.all? do |part|
                                part.casefolds.any? && part.value.each_char.one?
                              end)
          if class_repetition
            class_lengths = casefold_class_sequence_lengths(node.parts, characters, cursor, flags)
            return class_lengths.map { |length| [length, captures.dup] } unless class_lengths.empty?
          end

          states = [[0, captures]]
          parts = node.parts
          index = 0
          while index < parts.length
            part_index = index
            part = parts[index]
            if flags[:ignorecase] && part.is_a?(SemanticBytecode::Literal)
              # A UTF-8 case fold can consume several source literals, such
              # as `ss` matching one `ß`. Keep the bytecode nodes intact for
              # captures, but match one adjacent literal run as one operand.
              run = [part]
              index += 1
              while index < parts.length && parts[index].is_a?(SemanticBytecode::Literal)
                first_expands = (run.first.casefold || run.first.value).length > run.first.value.length
                next_literal = parts[index]
                next_expands = (next_literal.casefold || next_literal.value).length > next_literal.value.length
                break if !first_expands && next_expands

                run << parts[index]
                index += 1
              end
              run_value = run.map(&:value).join
              first_expands = (run.first.casefold || run.first.value).length > run.first.value.length
              has_mark = run_value.each_char.any? { |character| Onibi::UnicodeProperties.mark?(character) }
              reverse_fold = reverse_casefold_sequence?(run_value)
              folded_run = run.map { |literal| literal.casefold || literal.value }.join
              reverse_prefix = run.each_index.drop(1).reverse.find do |length|
                reverse_casefold_sequence?(run.first(length).map(&:value).join)
              end
              if reverse_prefix
                index = part_index + reverse_prefix
                prefix = run.first(reverse_prefix)
                prefix_value = prefix.map(&:value).join
                prefix_fold = prefix.map { |literal| literal.casefold || literal.value }.join
                part = SemanticBytecode::Literal.new(prefix_value, prefix_fold == prefix_value ? nil : prefix_fold,
                                                     nil, false)
              elsif run.length > 1 &&
                    (run_value.ascii_only? || first_expands || has_mark || reverse_fold || folded_run != run_value)
                part = SemanticBytecode::Literal.new(run_value, folded_run == run_value ? nil : folded_run,
                                                     nil, false)
              else
                index = part_index + 1
              end
            else
              index += 1
            end
            previous_states = states
            states = previous_states.flat_map do |consumed, state_captures|
              part_results = node_results(part, characters, cursor + consumed, state_captures, flags)
              optional_order = mri_casefold_optional_order?(part, parts[index], characters,
                                                            cursor + consumed, flags)
              if optional_order == :zero_only
                part_results = part_results.select { |length, _inner| length.zero? }
              elsif optional_order == :greedy
                part_results = part_results.sort_by { |length, _inner| length.zero? ? 1 : 0 }
              end
              previous_part = part_index.positive? ? parts[part_index - 1] : nil
              boundary_relaxed = mri_fold_boundary_relaxed?(previous_part, part, consumed) ||
                                 mri_fold_boundary_lookahead_relaxed?(previous_part, part,
                                                                      parts[index], characters,
                                                                      cursor + consumed)
              if !boundary_relaxed &&
                 mri_multi_fold_literal_boundary?(part, parts[index], characters,
                                                  cursor + consumed, flags)
                part_results = []
              end
              if !boundary_relaxed &&
                 mri_multi_fold_quantifier_boundary?(part, parts[index], characters,
                                                     cursor + consumed, flags)
                part_results = []
              end
              part_results.filter_map do |length, inner|
                if state_captures[:__zero_absence] &&
                   state_captures[:__match_start] == state_captures[:__match_end] &&
                   state_captures[:__match_start].is_a?(Integer) &&
                   state_captures[:__match_start] > cursor + consumed
                  next
                end

                inner = discard_absence_body_captures(part, inner) if part.is_a?(SemanticBytecode::Absence) &&
                                                                      part_index < parts.length - 1
                next_state = if node.parts.length > 1 && inner.key?(:__match_start) && !inner.key?(:__match_prefix)
                               marked = inner.dup
                               marked[:__match_prefix] = consumed
                               marked[:__match_prefix_value] = characters[cursor, consumed].join
                               marked[:__match_prefix_zero_absence] = state_captures[:__zero_absence]
                               marked
                             else
                               inner
                             end
                [consumed + length, next_state]
              end
            end
            next unless states.empty?

            folded = previous_states.flat_map do |consumed, state_captures|
              casefold_sequence_results(parts.drop(part_index), characters,
                                        cursor + consumed, state_captures, flags).map do |length, inner|
                [consumed + length, inner]
              end
            end
            return folded unless folded.empty?

            return []
          end
          states
        when SemanticBytecode::Conditional
          conditional_results(node, characters, cursor, captures, flags)
        when SemanticBytecode::Alternation
          branch_flags = flags.merge(fold_alternation: true)
          node.branches.each_with_index.flat_map do |branch, branch_index|
            node_results(branch, characters, cursor, captures, branch_flags).map do |length, state|
              marked = state.dup
              marked[:__match_alternative] = true
              marked[:__match_alternative_index] = branch_index
              [length, marked]
            end
          end
        when SemanticBytecode::Group
          node_results(node.body, characters, cursor, captures, flags).map do |length, inner|
            next_captures = inner.dup
            if node.capture
              next_captures[node.number] = [cursor, cursor + length]
              next_captures[node.name] = [cursor, cursor + length] if node.name
            end
            [length, next_captures]
          end
        when SemanticBytecode::Quantifier
          quantifier_results(node, characters, cursor, captures, flags)
        when SemanticBytecode::OptionGroup
          scoped_flags = flags.dup
          scoped_flags[:ignorecase] = node.ignorecase unless node.ignorecase.nil?
          scoped_flags[:multiline] = node.multiline unless node.multiline.nil?
          node_results(node.body, characters, cursor, captures, scoped_flags)
        when SemanticBytecode::AtomicGroup
          node_results(node.body, characters, cursor, captures, flags).first(1)
        when SemanticBytecode::Assertion
          assertion_results(node, characters, cursor, captures, flags)
        when SemanticBytecode::SubexpressionCall
          body = @subexpressions[node.identifier]
          return [] unless body
          return [] if (@subexpression_depth ||= 0) > 32

          @subexpression_depth += 1
          results = node_results(body, characters, cursor, captures, flags)
          @subexpression_depth -= 1
          results
        when SemanticBytecode::Absence
          absence_results(node, characters, cursor, captures, flags).map do |length, state|
            next [length, state] unless length.zero?

            marked = state.dup
            marked[:__zero_absence] = true
            [length, marked]
          end
        else
          if node.is_a?(SemanticBytecode::Escape) && node.kind == :grapheme
            lengths = grapheme_cluster_lengths(characters, cursor)
            return lengths.to_a.map { |length| [length, captures.dup] }
          end

          length = transition_length([operation_for(node), node], characters, cursor, flags, captures)
          return [] unless length

          if node.is_a?(SemanticBytecode::Escape) && node.kind == :match_reset
            next_captures = captures.dup
            next_captures[:__match_start] = cursor
            next_captures[:__match_reset] = true
            return [[length, next_captures]]
          end

          if length.zero? && flags[:multiline] && cursor == characters.length &&
             node.is_a?(SemanticBytecode::Anchor)
            marked = captures.dup
            marked[:__end_zero_width] = true
            return [[length, marked]]
          end

          if node.is_a?(SemanticBytecode::Property)
            return property_match_lengths(node, characters, cursor, flags).map do |property_length|
              [property_length, captures]
            end
          end

          if node.is_a?(SemanticBytecode::CharacterClass)
            return class_match_lengths(node, characters, cursor, flags).map do |class_length|
              [class_length, captures]
            end
          end

          [[length, captures]]
        end
      end

      # Onigmo can split one expanded fold across adjacent operands. For
      # example, `[s]s` matches one `ß` under `/i`. The normal cursor model
      # cannot split a Unicode character, so compare the operand run with its
      # virtual folded input and consume the original character width.
      def casefold_sequence_results(parts, characters, cursor, captures, flags)
        return [] unless flags[:ignorecase]

        prefix = []
        parts.each do |part|
          break if prefix.length >= 2
          break unless (prefix.empty? && part.is_a?(SemanticBytecode::CharacterClass)) ||
                       (prefix.length == 1 && part.is_a?(SemanticBytecode::Literal) &&
                        part.value.each_char.one?)

          prefix << part
        end
        return [] if prefix.length < 2 || prefix.first.value.start_with?("^")

        maximum = [characters.length - cursor, casefold_prefix_width(prefix)].min
        1.upto(maximum).filter_map do |width|
          slice = characters[cursor, width]
          if prefix.first.is_a?(SemanticBytecode::CharacterClass) &&
             slice.first&.downcase(:fold)&.length.to_i > 1 &&
             !prefix.first.split_casefold && !prefix.first.value.each_char.one?
            next
          end
          if prefix.first.is_a?(SemanticBytecode::CharacterClass) &&
             prefix.first.casefolds.any? &&
             slice.first.downcase(:fold).length == 1 &&
             slice.first != slice.first.downcase(:fold)
            next
          end

          folded = slice.join.downcase(:fold)
          expanded_class = prefix.first.split_casefold
          expected_fold_characters = prefix.flat_map do |part|
            if part.is_a?(SemanticBytecode::Literal)
              (part.casefold || part.value).each_char.to_a
            else
              part.casefolds.flat_map { |_source, value| value.each_char.to_a }
            end
          end.uniq
          next unless folded.each_char.all? { |character| expected_fold_characters.include?(character) }
          next unless folded_atoms_match?(prefix, folded, flags, allow_fold_tail: expanded_class)

          next [[width, captures.dup]] if prefix.length == parts.length

          suffix = SemanticBytecode::Sequence.new(parts.drop(prefix.length))
          node_results(suffix, characters, cursor + width, captures, flags).map do |length, inner|
            [width + length, inner]
          end
        end.flatten(1)
      end

      def casefold_prefix_width(parts)
        parts.sum do |part|
          if part.is_a?(SemanticBytecode::Literal)
            (part.casefold || part.value).length
          else
            lengths = part.casefolds.map { |_source, folded| folded.length }
            [1, *lengths].max
          end
        end
      end

      def casefold_class_sequence_lengths(parts, characters, cursor, flags)
        maximum = characters.length - cursor
        folded_pattern = parts.map { |part| part.value.downcase(:fold) }.join
        expanded_classes = parts.any? { |part| part.casefolds.any? } &&
                           parts.all? { |part| part.value.each_char.one? }
        1.upto(maximum).filter_map do |width|
          slice = characters[cursor, width]
          folded = slice.join.downcase(:fold)
          width if (expanded_classes && folded == folded_pattern) ||
                   (!expanded_classes && folded_atoms_match?(parts, folded, flags))
        end
      end

      # MRI changes branch order for an optional folded literal. With no
      # suffix it keeps the consuming branch first. With a different suffix,
      # it keeps only the empty branch, as in `s?a` matching `a` in `ſa`.
      def mri_casefold_optional_order?(node, next_node, characters, cursor, flags)
        return false unless flags[:ignorecase]
        return false unless node.is_a?(SemanticBytecode::Quantifier)
        return false unless node.minimum.zero? && node.maximum == 1 && node.mode == :greedy

        expression = node.expression
        return false unless expression.is_a?(SemanticBytecode::Literal)

        source = characters[cursor]
        return false unless source

        expression_special = expression.value.downcase(:fold) != expression.value.downcase
        return false unless source != expression.value || expression_special
        return false unless source.downcase(:fold) == expression.value.downcase(:fold)
        return :greedy unless next_node

        special_source = source.downcase(:fold) != source.downcase ||
                         (source == expression.value && expression_special)
        return :greedy unless special_source
        return :greedy if expression.value.downcase(:fold).length > expression.value.length
        return :greedy unless next_node.is_a?(SemanticBytecode::Literal) ||
                              next_node.is_a?(SemanticBytecode::CharacterClass) ||
                              next_node.is_a?(SemanticBytecode::Quantifier)
        return :greedy if next_node.is_a?(SemanticBytecode::Quantifier) && next_node.minimum.zero?
        if next_node.is_a?(SemanticBytecode::Quantifier) &&
           next_node.expression.is_a?(SemanticBytecode::CharacterClass) &&
           next_node.expression.casefolds.any?
          return :greedy
        end
        if next_node.is_a?(SemanticBytecode::Quantifier) &&
           next_node.expression.is_a?(SemanticBytecode::Literal) &&
           next_node.expression.casefold&.length.to_i > next_node.expression.value.length
          return :greedy
        end
        # Keep the consuming candidate when the following literal has an
        # expanding fold. For example, `s?ß` must match `ſẞ` from position 0.
        return :greedy if next_node.is_a?(SemanticBytecode::Literal) &&
                          next_node.casefold&.length.to_i > next_node.value.length
        return :greedy if next_node.is_a?(SemanticBytecode::CharacterClass) &&
                          next_node.casefolds.any?
        if next_node.is_a?(SemanticBytecode::Quantifier) &&
           next_node.expression.is_a?(SemanticBytecode::CharacterClass) &&
           next_node.maximum && next_node.maximum > next_node.minimum &&
           Onibi::ClassPredicates.matches?(next_node.expression.value,
                                           expression.value.downcase(:fold),
                                           ignorecase: true)
          return :greedy
        end
        if next_node.is_a?(SemanticBytecode::Quantifier) &&
           next_node.expression.is_a?(SemanticBytecode::CharacterClass) &&
           next_node.maximum && next_node.maximum > next_node.minimum &&
           same_fold_literal?(next_node, expression)
          return :greedy
        end
        return :zero_only if next_node.is_a?(SemanticBytecode::Quantifier) && next_node.maximum != 1
        return false if same_fold_literal?(next_node, expression)

        :zero_only
      end

      def same_fold_literal?(node, expression)
        literal = node
        literal = node.expression if node.is_a?(SemanticBytecode::Quantifier)
        literal = node if node.is_a?(SemanticBytecode::CharacterClass) && node.casefolds.empty?
        (literal.is_a?(SemanticBytecode::Literal) || literal.is_a?(SemanticBytecode::CharacterClass)) &&
          literal.value.downcase(:fold) == expression.value.downcase(:fold)
      end

      def mri_multi_fold_literal_boundary?(node, next_node, characters, cursor, flags)
        return false if flags[:fold_alternation]

        node = boundary_operand(node)
        next_node = boundary_operand(next_node)
        return false unless flags[:ignorecase] && node.is_a?(SemanticBytecode::Literal)
        return false unless node.casefold && node.casefold.length > node.value.length
        return false unless characters[cursor] == node.value
        return false unless node.fold_boundary_sensitive
        return false if next_node.is_a?(SemanticBytecode::CharacterClass)

        next_source = characters[cursor + 1]
        if next_source && next_source.downcase(:fold).length > 1 &&
           next_source.downcase(:fold) == next_node_value(next_node)
          return false
        end

        next_value = next_node_value(next_node)
        if next_value && later_sequence_fold_candidate?(next_value, characters,
                                                        cursor + 1 + next_value.length)
          return false
        end
        return true if next_node.is_a?(SemanticBytecode::Sequence) &&
                       next_node.parts.all? { |part| part.is_a?(SemanticBytecode::Literal) }

        if next_node.is_a?(SemanticBytecode::Quantifier)
          return false unless next_node.minimum.positive?
          return false if next_node.expression.is_a?(SemanticBytecode::CharacterClass) &&
                          next_node.expression.casefolds.any?
          if next_node.expression.is_a?(SemanticBytecode::Literal) &&
             next_node.expression.casefold&.length.to_i > next_node.expression.value.length
            return false
          end

          next_node = next_node.expression
        end
        return true if next_node.is_a?(SemanticBytecode::Literal)
        return false unless next_node.is_a?(SemanticBytecode::CharacterClass)

        !next_node.value.include?("[") && !next_node.value.include?(":") &&
          !next_node.value.include?("\\") && !next_node.value.include?("&&")
      end

      def next_node_value(node)
        return node.casefold || node.value if node.is_a?(SemanticBytecode::Literal)
        return node.parts.map { |part| part.casefold || part.value }.join if node.is_a?(SemanticBytecode::Sequence) &&
                                                                             node.parts.all? { |part| part.is_a?(SemanticBytecode::Literal) }

        nil
      end

      def boundary_operand(node)
        loop do
          if node.is_a?(SemanticBytecode::Group)
            node = node.body
          elsif node.is_a?(SemanticBytecode::Sequence) && node.parts.length == 1
            node = node.parts.first
          else
            return node
          end
        end
      end

      def mri_fold_boundary_lookahead_relaxed?(previous_node, node, next_node, characters, cursor)
        return false unless previous_node.is_a?(SemanticBytecode::Quantifier)
        return false unless previous_node.minimum.zero?
        return false unless previous_node.expression.is_a?(SemanticBytecode::Literal)
        return false unless node.is_a?(SemanticBytecode::Literal)
        return false unless previous_node.expression.value == node.value
        return false unless next_node.is_a?(SemanticBytecode::Quantifier)
        return false unless next_node.maximum && next_node.maximum > next_node.minimum
        return false unless next_node.expression.is_a?(SemanticBytecode::Literal)

        later_fold_candidate?(next_node.expression, characters, cursor + 2)
      end

      def later_fold_candidate?(literal, characters, cursor)
        fold = literal.casefold || literal.value
        characters.drop(cursor).any? { |character| character.downcase(:fold) == fold }
      end

      def later_sequence_fold_candidate?(fold, characters, cursor)
        characters.each_index.any? do |index|
          next false if index < cursor

          slice = characters[index, [fold.length, characters.length - index].min]
          slice && slice.join.downcase(:fold) == fold
        end
      end

      def later_class_candidate?(character_class, characters, cursor, flags)
        first = characters[cursor - 1]
        characters.drop(cursor).any? do |character|
          character != first &&
            Onibi::ClassPredicates.matches?(character_class.value, character,
                                            ignorecase: flags[:ignorecase],
                                            encoding: flags[:encoding])
        end
      end

      def mri_multi_fold_quantifier_boundary?(node, next_node, characters, cursor, flags)
        return false if flags[:fold_alternation]
        return false unless node.is_a?(SemanticBytecode::Quantifier)
        return false unless node.minimum.positive?
        return false if node.maximum.nil?
        if node.expression.is_a?(SemanticBytecode::CharacterClass) &&
           node.expression.value.each_char.one? &&
           node.expression.value.downcase(:fold) != node.expression.value &&
           characters[cursor] != node.expression.value &&
           characters[cursor] == characters[cursor]&.downcase(:fold) &&
           characters[cursor]&.downcase(:fold) == node.expression.value.downcase(:fold) &&
           next_node.is_a?(SemanticBytecode::Quantifier) && next_node.minimum.positive? &&
           next_node.maximum && next_node.expression.is_a?(SemanticBytecode::Literal) &&
           next_node.expression.value.downcase(:fold) != node.expression.value.downcase(:fold)
          return true
        end
        return false unless node.expression.is_a?(SemanticBytecode::Literal)
        return false if next_node.is_a?(SemanticBytecode::Quantifier) && next_node.minimum.zero?

        next_expression = next_node.is_a?(SemanticBytecode::Quantifier) ? next_node.expression : next_node
        if next_expression.is_a?(SemanticBytecode::CharacterClass)
          return false unless node.expression.casefold &&
                              node.expression.casefold.length > node.expression.value.length &&
                              node.expression.fold_boundary_sensitive
          return false if next_expression.casefolds.any?
          return false if next_expression.value.include?(":") || next_expression.value.include?("\\") ||
                          next_expression.value.include?("&&") || next_expression.value.start_with?("^")

          if next_node.is_a?(SemanticBytecode::Quantifier) && next_node.maximum.nil?
            first_class_character = characters[cursor + 1]
            return true unless first_class_character &&
                               first_class_character == first_class_character.downcase(:fold)

            return !later_class_candidate?(next_expression, characters, cursor + 2, flags)
          end
        elsif !next_expression.is_a?(SemanticBytecode::Literal)
          return false
        end

        mri_multi_fold_literal_boundary?(node.expression, next_node, characters, cursor, flags)
      end

      def mri_fold_boundary_relaxed?(previous_node, node, consumed)
        return false unless previous_node.is_a?(SemanticBytecode::Quantifier)
        return false unless previous_node.minimum.zero?
        return false unless consumed.positive?

        previous_expression = previous_node.expression
        current_expression = node.is_a?(SemanticBytecode::Quantifier) ? node.expression : node
        previous_expression.is_a?(SemanticBytecode::Literal) &&
          current_expression.is_a?(SemanticBytecode::Literal) &&
          previous_expression.value == current_expression.value
      end

      def reverse_casefold_sequence?(value)
        @reverse_casefold_sequences ||= {}
        return @reverse_casefold_sequences[value] if @reverse_casefold_sequences.key?(value)

        @reverse_casefold_sequences[value] = Onibi::UnicodeProperties.casefold_codepoints.any? do |codepoint|
          character = [codepoint].pack("U")
          character.downcase(:fold) == value
        end
      end

      def folded_atoms_match?(atoms, folded, flags, allow_fold_tail: false)
        return folded.empty? || allow_fold_tail if atoms.empty?

        atom = atoms.first
        if atom.is_a?(SemanticBytecode::Literal)
          value = atom.value.downcase(:fold)
          return false unless folded.start_with?(value)

          return folded_atoms_match?(atoms.drop(1), folded[value.length..], flags,
                                     allow_fold_tail: allow_fold_tail)
        end

        character = folded.each_char.first
        return false unless character

        matched = if atom.is_a?(SemanticBytecode::CharacterClass)
                    Onibi::ClassPredicates.matches?(atom.value, character,
                                                    ignorecase: true,
                                                    encoding: flags[:encoding]) ||
                      Array(atom.casefolds).any? { |_source, value| value.start_with?(character) }
                  else
                    false
                  end
        matched && folded_atoms_match?(atoms.drop(1), folded[character.length..], flags,
                                       allow_fold_tail: allow_fold_tail)
      end

      def quantifier_results(quantifier, characters, cursor, captures, flags = {})
        if captures[:__end_zero_width] && characters.join.bytesize > 1 && flags[:multiline] &&
           quantifier.mode != :lazy &&
           quantifier.minimum.zero? && quantifier.maximum.nil? &&
           quantifier.expression.is_a?(SemanticBytecode::Any) &&
           quantifier.expression.value == "."
          return []
        end

        if flags[:ignorecase] && quantifier.minimum == quantifier.maximum &&
           quantifier.minimum > 1 &&
           (quantifier.expression.is_a?(SemanticBytecode::Literal) ||
            quantifier.expression.is_a?(SemanticBytecode::CharacterClass))
          # A fixed repetition is one logical literal sequence. Matching each
          # operand alone would lose reverse folds such as `ſ{2}` versus `ß`.
          repeated = SemanticBytecode::Sequence.new(
            Array.new(quantifier.minimum, quantifier.expression)
          )
          repetition_flags = if quantifier.expression.is_a?(SemanticBytecode::CharacterClass)
                               flags.merge(casefold_repetition: true)
                             else
                               flags
                             end
          return node_results(repeated, characters, cursor, captures, repetition_flags)
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
            inner = clear_repeated_absence_captures(quantifier.expression, inner)
            if length.zero?
              expression = quantifier.expression
              expression = expression.body if expression.is_a?(SemanticBytecode::Group)
              if count.positive? && consumed.positive? &&
                 expression.is_a?(SemanticBytecode::Sequence)
                accepted << [consumed, inner] if count + 1 >= quantifier.minimum
                next
              end

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

        if quantifier.mode != :lazy && quantifier.maximum != quantifier.minimum &&
           nullable_single_quantifier?(quantifier.expression) &&
           !lazy_nullable_body?(quantifier.expression)
          accepted = accepted.group_by(&:first).values.map(&:last).sort_by { |length, _state| -length }
          group = quantifier.expression
          accepted = accepted.map do |length, state|
            next [length, state] if quantifier.maximum && length >= quantifier.maximum

            next_state = state.dup
            next_state[group.number] = [cursor + length, cursor + length]
            [length, next_state]
          end
        end

        return accepted unless mri_anchor_class_quantifier_fallback?(quantifier, accepted)

        zero_width = accepted.find { |length, _state| length.zero? }
        zero_width ? [zero_width] : accepted
      end

      def lazy_nullable_body?(node)
        body = node.is_a?(SemanticBytecode::Group) ? node.body : node
        parts = body.is_a?(SemanticBytecode::Sequence) ? body.parts : [body]
        parts.any? do |part|
          part.is_a?(SemanticBytecode::Quantifier) && part.mode == :lazy && part.minimum.zero?
        end
      end

      # MRI keeps the zero-width anchor branch when a bounded repetition of an
      # anchor alternation cannot complete its minimum count. Preserve that
      # ordered VM candidate instead of returning a partial match.
      def mri_anchor_class_quantifier_fallback?(quantifier, accepted)
        return false unless quantifier.kind == :bounded && quantifier.maximum
        return false unless quantifier.minimum && quantifier.minimum > 1
        return false unless accepted.any? { |length, _state| length.zero? }
        return false if accepted.any? { |length, _state| length >= quantifier.minimum }

        body = quantifier.expression
        body = body.body if body.is_a?(SemanticBytecode::Group)
        return false unless body.is_a?(SemanticBytecode::Alternation)

        branch_parts = body.branches.map do |branch|
          branch.is_a?(SemanticBytecode::Sequence) ? branch.parts : [branch]
        end
        consuming_branch = lambda do |part|
          part.is_a?(SemanticBytecode::CharacterClass) ||
            (quantifier.maximum != quantifier.minimum &&
             part.is_a?(SemanticBytecode::Literal))
        end
        branch_parts.any? { |parts| parts.any?(&consuming_branch) } &&
          branch_parts.any? do |parts|
            parts.any? do |part|
              part.is_a?(SemanticBytecode::Anchor) &&
                %i[anchor_start anchor_absolute_start].include?(part.kind)
            end
          end
      end

      def nullable_single_quantifier?(node)
        group = node if node.is_a?(SemanticBytecode::Group)
        body = group&.body
        return false unless body && minimum_node_width(body)&.zero?

        parts = body.is_a?(SemanticBytecode::Sequence) ? body.parts : [body]
        nested = parts.first
        nested.is_a?(SemanticBytecode::Quantifier) &&
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
        return nested_possessive_quantifier_results(quantifier, characters, cursor, captures, flags) if
          quantifier.expression.is_a?(SemanticBytecode::Quantifier)

        # A minimum-width analysis can be unknown for an alternation that
        # contains an anchor. Probe the compiled operand at input end too.
        # This lets a possessive repeat keep its terminal zero-width unit.
        nullable_body = minimum_node_width(quantifier.expression)&.zero? ||
                        node_results(quantifier.expression, characters, characters.length, captures, flags).any? do |length, _state|
                          length.zero?
                        end
        limit = quantifier.maximum || [characters.length - cursor + (nullable_body ? 1 : 0), 1].max
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
          current = adjust_possessive_absence_capture(quantifier.expression, cursor + consumed,
                                                      length, current)
          consumed += length
          count += 1
          accepted << [consumed, current] if count >= quantifier.minimum
          break if length.zero?
        end
        return [] if count < quantifier.minimum

        [accepted.last]
      end

      # MRI treats a bounded possessive suffix such as `{1,3}+` as a
      # possessive repetition of the bounded unit. Keep all unit widths in
      # the compiled execution path so a following operand can select the
      # first valid greedy unit without reopening the outer repeat.
      def nested_possessive_quantifier_results(quantifier, characters, cursor, captures, flags)
        frontier = [[0, captures]]
        accepted = quantifier.minimum.zero? ? [[0, captures]] : []
        ordered_zero = nil
        limit = characters.length - cursor + 1
        count = 0
        while count < limit && !frontier.empty?
          next_frontier = []
          frontier.each do |consumed, state|
            node_results(quantifier.expression, characters, cursor + consumed, state, flags).each do |length, inner|
              if length.zero? && !zero_width_nested_unit_valid?(quantifier.expression, characters,
                                                                cursor + consumed, state, flags)
                next
              end

              next_count = count + 1
              zero_width_state = inner != state || inner.key?(:__match_alternative)
              ordered_zero = [consumed + length, inner] if count.zero? && length.zero? &&
                                                           zero_width_state && ordered_zero.nil? &&
                                                           !(quantifier.expression.is_a?(SemanticBytecode::Quantifier) &&
                                                             quantifier.expression.mode == :lazy &&
                                                             quantifier.expression.minimum.zero?)
              accepted << [consumed + length, inner] if next_count >= quantifier.minimum
              next if length.zero?

              next_frontier << [consumed + length, inner]
            end
          end
          frontier = next_frontier
          count += 1
        end
        return [] if accepted.empty?
        return [ordered_zero] if ordered_zero

        # A zero-width nested unit can update captures without changing the
        # cursor. Prefer the state with the most capture data at an equal
        # width. Keep the latest state when capture data has the same shape.
        accepted.group_by(&:first).values.map do |candidates|
          if quantifier.expression.is_a?(SemanticBytecode::Quantifier) &&
             quantifier.expression.mode == :lazy && quantifier.expression.minimum.zero?
            candidates.first
          else
            candidates.each_with_index.max_by do |(_length, state), index|
              [state.count { |key, _value| key.is_a?(Integer) || key.is_a?(String) }, index]
            end.first
          end
        end.sort_by do |length, _state|
          if quantifier.expression.is_a?(SemanticBytecode::Quantifier) &&
             quantifier.expression.mode == :lazy && quantifier.expression.minimum.zero?
            length
          else
            -length
          end
        end
      end

      def zero_width_nested_unit_valid?(node, characters, cursor, captures, flags)
        if node.is_a?(SemanticBytecode::Group) || node.is_a?(SemanticBytecode::OptionGroup) ||
           node.is_a?(SemanticBytecode::AtomicGroup)
          return zero_width_nested_unit_valid?(node.body, characters, cursor, captures, flags)
        end
        if node.is_a?(SemanticBytecode::Sequence) && node.parts.length == 1
          return zero_width_nested_unit_valid?(node.parts.first, characters, cursor, captures, flags)
        end
        return false if characters.empty? && node.is_a?(SemanticBytecode::Escape) &&
                        %i[word_boundary not_word_boundary].include?(node.kind)
        return !node_results(node, characters, cursor, captures, flags).empty? unless
          node.is_a?(SemanticBytecode::Quantifier)
        return true if node.minimum.zero?
        return zero_width_nested_unit_valid?(node.expression, characters, cursor, captures, flags) if
          node.is_a?(SemanticBytecode::Quantifier)

        !node_results(node, characters, cursor, captures, flags).empty?
      end

      def transition_lengths(label, characters, cursor, captures, flags = {})
        opcode, operand = label
        return quantifier_lengths(operand, characters, cursor) if opcode == :match_quantifier
        return grapheme_cluster_lengths(characters, cursor) if opcode == :match_escape && operand.kind == :grapheme

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
            casefold_lengths(value.join, characters, cursor,
                             folded: operand.casefold,
                             expanded_only: flags[:lookbehind_casefold]).first
          else
            input_codepoints = characters[cursor, value.length]&.map(&:ord)
            input_codepoints == value.map(&:ord) ? value.length : nil
          end
        when :match_class
          class_match_lengths(operand, characters, cursor, flags).first
        when :match_any
          cursor < characters.length && (flags[:multiline] || operand.value != "." || characters[cursor] != "\n") ? 1 : nil
        when :match_escape
          case operand.kind
          when :grapheme
            grapheme_cluster_length(characters, cursor)
          when :word_boundary, :not_word_boundary
            left = cursor.positive? && boundary_word?(characters[cursor - 1], flags[:encoding])
            right = cursor < characters.length && boundary_word?(characters[cursor], flags[:encoding])
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
            if cursor < characters.length &&
               Onibi::CharacterPredicates.escape_matches?(operand.kind, characters[cursor], encoding: flags[:encoding])
              1
            end
          end
        when :match_property
          property_match_lengths(operand, characters, cursor, flags).first
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
        if quantifier.expression.is_a?(SemanticBytecode::Group)
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
        if quantifier.expression.is_a?(SemanticBytecode::Group)
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
           operand.expression.is_a?(SemanticBytecode::Group)
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
        return unless node.is_a?(SemanticBytecode::Sequence)

        group = node.parts.find do |part|
          part.is_a?(SemanticBytecode::Group) && part.capture
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
          matched = flags[:ignorecase] ? simple_casefold_equal?(value.join, candidate.join) : candidate == value
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

      def conditional_results(conditional, characters, cursor, captures, flags)
        condition = conditional.condition
        key = condition.is_a?(Array) ? condition[0] : condition
        branch = captures.key?(key) ? conditional.yes_branch : conditional.no_branch
        return [] unless branch

        node_results(branch, characters, cursor, captures, flags)
      end

      def atom_matches?(expression, character, flags = {})
        case expression
        when SemanticBytecode::Literal
          flags[:ignorecase] ? expression.value.casecmp?(character) : expression.value == character
        when SemanticBytecode::CharacterClass
          Onibi::ClassPredicates.matches?(expression.value, character,
                                          ignorecase: flags[:ignorecase],
                                          encoding: flags[:encoding])
        when SemanticBytecode::Escape
          Onibi::CharacterPredicates.escape_matches?(expression.kind, character, encoding: flags[:encoding])
        when SemanticBytecode::Property
          matched = property_matches?(expression.name, character, flags[:ignorecase] && !expression.negated,
                                      flags[:encoding])
          return expression.negated if matched == :incompatible

          expression.negated ? !matched : matched
        when SemanticBytecode::Any
          flags[:multiline] || expression.value != "." || character != "\n"
        else false
        end
      end

      # Return all lengths that one property bytecode operand can consume.
      # MRI keeps these reverse case-fold edges in its generated Onigmo table.
      # The direct edge stays first, so an unconstrained match keeps MRI's
      # leftmost-shortest result. Backtracking can then try a fold expansion
      # when a following anchor or assertion requires it.
      def property_match_lengths(operand, characters, cursor, flags)
        return [] if cursor >= characters.length

        character = unicode_character(characters[cursor])
        # A bare negated property also receives MRI's case-fold closure.
        # Character-class negation is handled separately by ClassPredicates.
        matched = property_matches?(operand.name, character, flags[:ignorecase], flags[:encoding])
        lengths = []
        if matched == :incompatible
          return operand.negated ? [1] : []
        end

        lengths << 1 if operand.negated ? !matched : matched
        return lengths unless flags[:ignorecase] && !operand.negated

        Array(operand.casefolds).each do |_source, folded|
          width = folded.length
          slice = characters[cursor, width]
          next unless slice && slice.length == width

          candidate = slice.join
          next unless casefold_equal?(folded, candidate)

          lengths << width unless lengths.include?(width)
        end
        lengths
      end

      def sequence_length(node, characters, cursor, flags = {})
        parts = if node.is_a?(SemanticBytecode::Sequence)
                  node.parts
                else
                  [node]
                end
        position = cursor
        parts.each do |part|
          length = case part
                   when SemanticBytecode::Quantifier
                     quantifier_length(part, characters, position, flags)
                   when SemanticBytecode::Group
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
        when SemanticBytecode::Literal then :match_literal
        when SemanticBytecode::CharacterClass then :match_class
        when SemanticBytecode::Any then :match_any
        when SemanticBytecode::Escape then :match_escape
        when SemanticBytecode::Property then :match_property
        when SemanticBytecode::Backreference then :match_backreference
        when SemanticBytecode::Conditional then :match_conditional
        when SemanticBytecode::Absence then :match_absence
        when SemanticBytecode::Assertion then :match_assertion
        when SemanticBytecode::Anchor then :test_anchor
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

      # The VM dispatch keeps all OP_ABSENT state transitions in one method.
      # rubocop:disable Metrics/BlockLength
      def absence_results(node, characters, cursor, captures, flags)
        # A literal delimiter is a safe fast path only when its body has no
        # capture. The wrapped body still owns capture state in MRI.
        # The literal delimiter shortcut performs exact string search. Case-folded
        # absence must use the bytecode probe, because the forbidden body may match
        # a different code point or a multi-codepoint fold.
        delimiter = literal_value(node.body) unless capture_numbers(node.body).any? || flags[:ignorecase]
        return absence_lengths(node, characters, cursor, flags).map { |length| [length, captures] } if delimiter

        frame = AbsentFrame.new(
          absent_start: cursor,
          absent_end: characters.length,
          probe_position: cursor,
          possible_points: [],
          body_checkpoints: [],
          capture_checkpoints: []
        )

        body_at_cursor = node_results(node.body, characters, cursor, captures, flags)
        first_result = body_at_cursor.find { |length, _state| length.positive? } || body_at_cursor.first
        first_length = first_result&.first
        first_state = first_result&.last || {}
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

        return [] if zero_width_quantifier_absence?(node.body, characters, cursor, flags)

        zero_width = zero_width_absence_results(node.body, characters, cursor, captures, flags)
        if zero_width
          unless nested_quantifier_suffix_body?(node.body)
            return zero_width.map do |length, state|
              [length, filter_outer_quantifier_suffix_captures(node.body, state, characters, flags)]
            end
          end

          return zero_width.map do |length, state|
            [length, filter_quantifier_suffix_captures(node.body, state, characters, flags)]
          end
        end

        if !flags[:ignorecase] && nested_quantifier_suffix_body?(node.body) &&
           (body_match_exists_after_probe?(node.body, characters, cursor, captures, flags) ||
            prefix_quantifier_match_exists?(node.body, characters, cursor, captures, flags))
          return nested_quantifier_suffix_results(node.body, characters, cursor, captures, flags)
        end

        if !flags[:ignorecase] && outer_quantifier_suffix_body?(node.body)
          return outer_quantifier_suffix_absence_results(node.body, characters, cursor, captures, flags)
        end

        return bounded_quantifier_absence_results(node.body, characters, cursor, captures, flags) if !flags[:ignorecase] && bounded_quantifier_body?(node.body)

        if !flags[:ignorecase] && nested_unbounded_quantifier_body?(node.body)
          return nested_unbounded_quantifier_absence_results(node.body, characters, cursor, captures, flags)
        end

        quantified_suffix = flags[:ignorecase] ? nil : quantified_suffix_absence_results(node.body, characters, cursor, captures, flags)
        return quantified_suffix if quantified_suffix

        quantified = quantified_absence_length(node.body, characters, cursor, flags)
        if quantified
          body_results = node_results(node.body, characters, cursor, captures, flags)
          body_result = body_results.find { |length, _state| length.positive? } || body_results.first
          body_captures = body_result ? body_result.last : captures
          body_captures = body_captures.dup
          body_captures.delete(:__match_start)
          body_captures = captures if captureless_absence_body?(node.body)
          body_captures = adjust_nested_repeat_capture(node.body, body_captures, body_result&.first, cursor)
          body_captures = filter_nested_absence_captures(node.body, body_captures)
          body_captures = filter_quantifier_suffix_captures(node.body, body_captures, characters, flags) if nested_quantifier_suffix_body?(node.body)
          body_captures = filter_outer_quantifier_suffix_captures(node.body, body_captures, characters, flags)
          body_captures = filter_absence_capture_scope(node.body, body_captures)
          return quantified.downto(0).map { |length| [length, body_captures] }
        end

        failure_state = nil
        cursor.upto(characters.length) do |position|
          results = node_results(node.body, characters, position, captures, flags)
          record_absence_checkpoint(frame, position, results, captures)
          if results.empty?
            candidate = sequence_failure_state(node.body, characters, position, captures, flags)
            failure_state = candidate.first if candidate && candidate.last == characters.length && candidate.first.keys.any? { |key| key.is_a?(Integer) }
            next
          end

          preferred = if results.any? { |_candidate, state| state.key?(:__match_alternative) }
                        results.find { |_candidate, state| !state.key?(:__match_start) }
                      end
          length, inner_captures = preferred || results.find { |candidate, _state| candidate.positive? } || results.first
          if flags[:ignorecase] && length.zero? && results.none? { |candidate, _state| candidate.positive? }
            next if position < characters.length

            return [[characters.length - cursor, inner_captures]]
          end
          inner_captures = inner_captures.dup
          internal_start = inner_captures.delete(:__match_start)
          internal_end = inner_captures.delete(:__match_end)
          internal_prefix = inner_captures.delete(:__match_prefix)
          internal_prefix_value = inner_captures.delete(:__match_prefix_value)
          internal_probe = inner_captures.delete(:__match_probe)
          inner_captures.delete(:__match_alternative)
          internal_alternative_index = inner_captures.delete(:__match_alternative_index)
          inner_captures.delete(:__zero_absence)
          prefix_zero_absence = inner_captures.delete(:__match_prefix_zero_absence)
          inner_captures = captures if captureless_absence_body?(node.body)
          inner_captures = adjust_nested_repeat_capture(node.body, inner_captures, length, position)
          inner_captures = filter_nested_absence_captures(node.body, inner_captures)
          inner_captures = filter_outer_quantifier_suffix_captures(node.body, inner_captures, characters, flags)
          inner_captures = filter_absence_capture_scope(node.body, inner_captures)
          inner_captures = discard_failed_quantified_suffix_captures(
            node.body, characters, cursor, inner_captures, flags
          )
          inner_captures = filter_quantifier_suffix_captures(node.body, inner_captures, characters, flags) if nested_quantifier_suffix_body?(node.body)
          quantified_length = quantified_absence_length(node.body, characters, position, flags)
          match_position = internal_start || position
          maximum = if quantified_length
                      match_position - cursor + quantified_length
                    elsif length.zero? && match_position > cursor
                      characters.length - cursor
                    elsif internal_alternative_index&.positive? && internal_start && internal_prefix.nil?
                      internal_start - cursor
                    elsif internal_end
                      effective_length = internal_end - internal_start
                      prefix_length = internal_prefix || 0
                      suffix_length = length - prefix_length - effective_length
                      if suffix_length.positive?
                        internal_end - cursor - 1
                      elsif prefix_zero_absence && internal_prefix&.positive? && effective_length.zero?
                        0
                      elsif prefix_zero_absence && internal_prefix&.zero? && effective_length.positive?
                        internal_end - cursor - 1
                      elsif internal_prefix_value && internal_probe && internal_prefix_value == internal_probe
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
        if failure_state
          failure_captures = filter_nested_absence_captures(node.body, failure_state)
          failure_captures = filter_quantifier_suffix_captures(node.body, failure_captures, characters, flags) if nested_quantifier_suffix_body?(node.body)
          failure_captures = filter_outer_quantifier_suffix_captures(node.body, failure_captures, characters, flags)
          failure_captures = filter_absence_capture_scope(node.body, failure_captures)
          if cursor == characters.length
            failure_captures.delete_if do |key, value|
              key.is_a?(Integer) && value.is_a?(Array) && value[0] == value[1]
            end
          end
          maximum = characters.length - cursor
          return maximum.downto(0).map { |length| [length, failure_captures] }
        end
        maximum = characters.length - cursor
        maximum.downto(0).map { |length| [length, captures] }
      end
      # rubocop:enable Metrics/BlockLength

      def record_absence_checkpoint(frame, position, results, captures)
        frame.probe_position = position
        frame.possible_points << [position, captures]
        frame.body_checkpoints << [position, results]
      end

      def bounded_quantifier_body?(body)
        quantifier = bounded_absence_quantifier(body)
        return false unless quantifier

        quantifier.is_a?(SemanticBytecode::Quantifier) &&
          quantifier.kind == :bounded
      end

      def bounded_absence_quantifier(node)
        parts = absence_sequence_parts(node)
        return nil unless parts.length == 1

        part = parts.first
        return part if part.is_a?(SemanticBytecode::Quantifier)
        return bounded_absence_quantifier(part.body) if part.is_a?(SemanticBytecode::Group)

        nil
      end

      def bounded_body_has_capture?(node)
        case node
        when SemanticBytecode::Group
          true
        when SemanticBytecode::Sequence
          node.parts.any? { |part| bounded_body_has_capture?(part) }
        when SemanticBytecode::Alternation
          node.branches.any? { |branch| bounded_body_has_capture?(branch) }
        when SemanticBytecode::Quantifier
          bounded_body_has_capture?(node.expression)
        else
          false
        end
      end

      def bounded_wrapper_capture?(node)
        first = absence_sequence_parts(node).first
        first.is_a?(SemanticBytecode::Group) &&
          bounded_quantifier_body?(node)
      end

      def nested_unbounded_quantifier_body?(body)
        quantifier = bounded_absence_quantifier(body)
        return false unless quantifier

        quantifier.maximum.nil? && %i[* +].include?(quantifier.kind) &&
          absence_sequence_parts(body).first.is_a?(SemanticBytecode::Group)
      end

      def nested_quantifier_suffix_body?(body)
        first = absence_sequence_parts(body).first
        return false unless first.is_a?(SemanticBytecode::Group)

        scope = quantifier_suffix_scope(body)
        scope && scope[1] &&
          (scope[2].to_i > 1 || static_node_width(scope.first.expression).nil? ||
           absence_sequence_parts(body).drop(1).any? do |part|
             capture_numbers(part).any?
           end)
      end

      def outer_quantifier_suffix_body?(body)
        parts = absence_sequence_parts(body)
        outer = parts.first
        return false unless parts.length > 1 &&
                            outer.is_a?(SemanticBytecode::Group)

        nested = absence_sequence_parts(outer.body)
        quantifier = nested.first
        nested.length == 1 &&
          quantifier.is_a?(SemanticBytecode::Quantifier) &&
          static_node_width(quantifier.expression) &&
          minimum_suffix_width(parts.drop(1))&.positive? &&
          parts.drop(1).none? { |part| capture_numbers(part).any? }
      end

      def outer_quantifier_suffix_absence_results(body, characters, cursor, captures, flags)
        absence_bounded_probe_results(body, characters, cursor, captures, flags,
                                      preserve_failed_capture: false).map do |length, state|
          restored = restore_outer_quantifier_suffix_checkpoint(
            body, length,
            { characters: characters, cursor: cursor, captures: captures, flags: flags, state: state }
          )
          [length, filter_bounded_absence_captures(body, restored)]
        end
      end

      def quantifier_node?(node)
        node.is_a?(SemanticBytecode::Quantifier)
      end

      def body_match_exists_after_probe?(body, characters, cursor, captures, flags)
        cursor.upto(characters.length) do |position|
          return true if node_results(body, characters, position, captures, flags).any?
        end
        false
      end

      def prefix_quantifier_match_exists?(body, characters, cursor, captures, flags)
        scope = quantifier_suffix_scope(body)
        return false unless scope

        minimum = minimum_node_width(scope.first.expression)
        cursor.upto(characters.length) do |position|
          results = node_results(scope.first.expression, characters, position, captures, flags)
          return true if results.any? { |length, _state| length > minimum }
        end
        false
      end

      def quantifier_suffix_scope(body)
        parts = absence_sequence_parts(body)
        suffix = parts.length > 1
        depth = 0
        parent = nil
        loop do
          first = parts.first
          return [first, suffix, depth, parent] if quantifier_node?(first)
          return nil unless first.is_a?(SemanticBytecode::Group)

          parent = first
          nested = absence_sequence_parts(first.body)
          suffix ||= nested.length > 1
          parts = nested
          depth = (depth || 0) + 1
        end
      end

      def nested_quantifier_suffix_results(body, characters, cursor, captures, flags)
        scope = quantifier_suffix_scope(body)
        absence_bounded_probe_results(body, characters, cursor, captures, flags,
                                      preserve_failed_capture: false).map do |length, state|
          state = restore_nested_suffix_checkpoint(
            state, length,
            { body: body, characters: characters, cursor: cursor,
              captures: captures, flags: flags, scope: scope }
          )
          [length, filter_quantifier_suffix_captures(body, state, characters, flags)]
        end
      end

      def restore_nested_suffix_checkpoint(state, length, context)
        body = context[:body]
        characters = context[:characters]
        cursor = context[:cursor]
        captures = context[:captures]
        flags = context[:flags]
        scope = context[:scope]
        return state unless state.empty? && scope&.fetch(2, 0).to_i.positive?

        endpoint = cursor + length
        checkpoint = nil
        checkpoint_position = nil
        cursor.upto([endpoint - 1, characters.length].min) do |position|
          results = node_results(body, characters, position, captures, flags)
          target_end = endpoint + 1
          candidate = results.find { |body_length, _state| position + body_length == target_end }&.last
          if candidate && checkpoint.nil?
            checkpoint = candidate
            checkpoint_position = position
          end
        end
        unless checkpoint
          return restore_prefix_quantifier_checkpoint(
            state, endpoint,
            { body: body, characters: characters, cursor: cursor,
              captures: captures, flags: flags, scope: scope }
          )
        end

        suffix_numbers = absence_sequence_parts(body).drop(1).flat_map { |part| capture_numbers(part) }
        return state if suffix_numbers.empty? && scope[2].to_i == 1 && checkpoint_position != cursor

        parent = scope[3]
        expression_number = capture_numbers(scope.first.expression).first
        value = checkpoint[expression_number]
        return state if suffix_numbers.empty? && scope[2].to_i == 1 &&
                        value.is_a?(Array) && value[0] != cursor

        restored = {}
        if parent && value.is_a?(Array) && value.length == 2 &&
           value[1] - value[0] == minimum_node_width(scope.first.expression)
          restored[parent.number] = value
        end

        hidden = capture_numbers(scope.first.expression)
        repetition_count = if parent&.number && checkpoint[parent.number].is_a?(Array)
                             span = checkpoint[parent.number]
                             quantifier_repetition_path_count(
                               scope.first.expression, characters, span[0], span[1], flags
                             )
                           else
                             0
                           end
        expression_reaches_checkpoint = suffix_numbers.any? &&
                                        quantifier_repetition_path_count(
                                          scope.first.expression, characters, cursor, checkpoint_position, flags
                                        ).positive?
        if parent && !restored.key?(parent.number) && (suffix_numbers.empty? || repetition_count == 1) &&
           !expression_reaches_checkpoint
          checkpoint.each do |key, candidate|
            next unless key.is_a?(Integer) && key >= parent.number
            next if key == parent.number || hidden.include?(key)

            restored[key] = candidate
          end
        end
        restored.empty? ? state : restored
      end

      def restore_prefix_quantifier_checkpoint(state, endpoint, context)
        body = context[:body]
        characters = context[:characters]
        cursor = context[:cursor]
        captures = context[:captures]
        flags = context[:flags]
        scope = context[:scope]
        parent = scope[3]
        return state unless parent
        return state if node_results(body, characters, cursor, captures, flags).any? do |length, _checkpoint|
          cursor + length == endpoint
        end

        expression = scope.first.expression
        minimum = minimum_node_width(expression)
        wide_seen = false
        candidate = nil
        cursor.upto([endpoint - 1, characters.length].min) do |position|
          node_results(expression, characters, position, captures, flags).each do |length, checkpoint|
            wide_seen ||= length > minimum
            next unless wide_seen && length == minimum

            suffix_numbers = absence_sequence_parts(body).drop(1).flat_map { |part| capture_numbers(part) }
            next if suffix_numbers.any? &&
                    position + length != endpoint

            candidate = checkpoint[capture_numbers(expression).first]
          end
        end
        value = candidate
        value.is_a?(Array) && value.length == 2 ? { parent.number => value } : state
      end

      def filter_quantifier_suffix_captures(body, captures, characters, flags)
        scope = quantifier_suffix_scope(body)
        if scope
          quantifier, suffix = scope
          if suffix
            suffix_numbers = absence_sequence_parts(body).drop(1).flat_map { |part| capture_numbers(part) }
            hidden = capture_numbers(quantifier.expression)
            parent = quantifier_suffix_scope(body)[3]
            parent_span = parent && captures[parent.number]
            if suffix_numbers.empty? && parent_span.is_a?(Array) &&
               quantifier_repetition_count(
                 quantifier.expression, characters, parent_span[0], parent_span[1], flags
               ) > 1
              return captures.reject { |key, _value| key.is_a?(Integer) && hidden.include?(key) }
            end

            outer = absence_sequence_parts(body).first
            suffix_body = outer ? absence_sequence_parts(outer.body).drop(1) : []
            if suffix_numbers.empty? && static_node_width(quantifier.expression) &&
               parent_span.is_a?(Array) && suffix_body.any?
              suffix_matches = node_results(
                Onibi::IRGen::YARVIR::SemanticBytecode::Sequence.new(suffix_body),
                characters, parent_span[1], captures, flags
              ).any? { |length, _state| length.positive? }
              unless suffix_matches
                discard = hidden + [parent&.number]
                return captures.reject { |key, _value| key.is_a?(Integer) && discard.include?(key) }
              end
            end
            if suffix_numbers.empty? && scope[2].to_i > 1 && outer
              nested_parts = absence_sequence_parts(outer.body)
              suffix_body = nested_parts.drop(1)
              suffix_matches = parent_span.is_a?(Array) && suffix_body.any? &&
                               node_results(
                                 Onibi::IRGen::YARVIR::SemanticBytecode::Sequence.new(suffix_body),
                                 characters, parent_span[1], captures, flags
                               ).any? { |length, _state| length.positive? }
              unless suffix_matches
                discard = hidden + [parent&.number]
                return captures.reject { |key, _value| key.is_a?(Integer) && discard.include?(key) }
              end
            end
            if suffix_numbers.empty? && parent_span.is_a?(Array) && parent_span[1] == characters.length
              return captures.reject { |key, _value| key.is_a?(Integer) && hidden.include?(key) }
            end

            if parent_span.is_a?(Array) && parent_span.length == 2
              repetitions = quantifier_repetition_count(
                quantifier.expression, characters, parent_span[0], parent_span[1], flags
              )
              if repetitions > 1
                return captures.reject do |key, _value|
                  key.is_a?(Integer) && (hidden.include?(key) || suffix_numbers.include?(key))
                end
              end
            end
            return captures.reject { |key, _value| key.is_a?(Integer) && hidden.include?(key) }
          end
        end

        filter_nested_quantifier_suffix_captures(body, captures, characters, flags)
      end

      def filter_outer_quantifier_suffix_captures(body, captures, characters, flags)
        parts = absence_sequence_parts(body)
        outer = parts.first
        return captures unless parts.length > 1 &&
                               outer.is_a?(SemanticBytecode::Group)
        return captures unless minimum_suffix_width(parts.drop(1))&.positive?

        nested = absence_sequence_parts(outer.body)
        quantifier = nested.first
        return captures unless nested.length == 1 &&
                               quantifier.is_a?(SemanticBytecode::Quantifier)
        return captures unless static_node_width(quantifier.expression)

        outer_span = captures[outer.number]
        return captures unless outer_span.is_a?(Array) && outer_span.length == 2

        suffix = SemanticBytecode::Sequence.new(parts.drop(1))
        suffix_matches = node_results(suffix, characters, outer_span[1], captures, flags).any? do |length, _state|
          length.positive?
        end
        hidden = [outer.number] + capture_numbers(quantifier.expression)
        return captures.reject { |key, _value| key.is_a?(Integer) && hidden.include?(key) } unless suffix_matches

        expression_number = capture_numbers(quantifier.expression).first
        last_capture = captures[expression_number]
        return captures unless last_capture.is_a?(Array) && last_capture.length == 2

        captures.reject { |key, _value| key.is_a?(Integer) && hidden.include?(key) }
                .merge(outer.number => last_capture)
      end

      def nested_nullable_repeat_body?(body)
        quantifier = bounded_absence_quantifier(body)
        quantifier && quantifier.minimum.to_i.zero? &&
          %i[* bounded].include?(quantifier.kind)
      end

      def nested_unbounded_quantifier_absence_results(body, characters, cursor, captures, flags)
        result = absence_bounded_probe_results(body, characters, cursor, captures, flags,
                                               preserve_failed_capture: false).first
        return [] unless result && result.first >= 0

        length, state = result
        state = restore_outer_quantifier_suffix_checkpoint(
          body, length,
          { characters: characters, cursor: cursor, captures: captures, flags: flags, state: state }
        )
        [[length, filter_bounded_absence_captures(body, state)]]
      end

      def restore_outer_quantifier_suffix_checkpoint(body, length, context)
        characters = context[:characters]
        cursor = context[:cursor]
        captures = context[:captures]
        flags = context[:flags]
        state = context[:state]
        parts = absence_sequence_parts(body)
        outer = parts.first
        return state unless parts.length > 1 &&
                            outer.is_a?(SemanticBytecode::Group)

        nested = absence_sequence_parts(outer.body)
        quantifier = nested.first
        return state unless nested.length == 1 &&
                            quantifier.is_a?(SemanticBytecode::Quantifier)
        return state unless static_node_width(quantifier.expression)
        return state if parts.drop(1).any? { |part| capture_numbers(part).any? }

        endpoint = cursor + length
        checkpoint = nil
        cursor.upto([endpoint - 1, characters.length].min) do |position|
          candidate = node_results(body, characters, position, captures, flags).find do |body_length, _inner|
            position + body_length == endpoint + 1
          end
          checkpoint = candidate.last if candidate && checkpoint.nil?
        end
        return state unless checkpoint

        value = checkpoint[capture_numbers(quantifier.expression).first]
        return state unless value.is_a?(Array) && value.length == 2

        state.reject { |key, _value| key.is_a?(Integer) }.merge(outer.number => value)
      end

      def filter_bounded_absence_captures(body, state)
        capture = absence_sequence_parts(body).first
        keep = (capture.number if capture.is_a?(SemanticBytecode::Group))
        state.reject { |key, _value| key.is_a?(Integer) && key != keep }
      end

      def bounded_quantifier_absence_results(body, characters, cursor, captures, flags)
        absence_bounded_probe_results(body, characters, cursor, captures, flags,
                                      preserve_failed_capture: false).map do |length, state|
          state = filter_bounded_absence_captures(body, state)
          [length, state]
        end
      end

      def quantified_suffix_absence_results(body, characters, cursor, captures, flags = {})
        parts = absence_sequence_parts(body)
        quantifier = parts.first
        return unless parts.length > 1 &&
                      quantifier.is_a?(SemanticBytecode::Quantifier)
        return if contains_absence_node?(body)

        suffix_minimum = minimum_suffix_width(parts.drop(1))
        if %i[* + ?].include?(quantifier.kind) &&
           (suffix_minimum&.positive? || suffix_can_consume?(parts.drop(1)))
          return absence_bounded_probe_results(
            body, characters, cursor, captures, flags,
            preserve_failed_capture: preserve_quantifier_capture?(quantifier, parts, characters,
                                                                  cursor, flags)
          )
        end

        return unless quantifier.maximum.nil?

        repeated_atom = parts.length == 2 && quantifier.kind == :+ &&
                        repeated_quantified_atom_suffix?(quantifier, parts[1])
        return unless %i[* +].include?(quantifier.kind)

        if repeated_atom
          atom = literal_value(quantifier.expression)
          run = quantified_atom_run_length(quantifier.expression, characters, cursor, flags)
          return unless run >= quantifier.minimum

          results = node_results(body, characters, cursor, captures, flags)
          target = results.find { |length, _state| length == run }
          return unless target

          return if quantified_atom_matches?(quantifier.expression, characters, cursor + run, flags)

          state = target.last.dup
          state.delete_if { |key, _value| key.is_a?(Symbol) && key.to_s.start_with?("__") }
          suffix = parts[1]
          boundary = suffix.is_a?(SemanticBytecode::Quantifier)
          boundary = boundary && suffix.kind == :* ? run / 2 : (run + 1) / 2
          return [[boundary, state]]
        end

        if quantifier.kind == :+
          atom = literal_value(quantifier.expression)
          run = quantified_atom_run_length(quantifier.expression, characters, cursor, flags)
          if run >= 3 && !quantified_atom_matches?(quantifier.expression, characters, cursor + run, flags)
            results = node_results(body, characters, cursor, captures, flags)
            minimum = results.map(&:first).min
            boundary = if cursor + run == characters.length && minimum
                         minimum
                       elsif atom.nil? && cursor + run == characters.length
                         (run + 1) / 2
                       else
                         (run + 2) / 2
                       end
            target = results.find { |length, _state| length == boundary + 1 }
            if target
              state = target.last.dup
              state.delete_if { |key, _value| key.is_a?(Symbol) && key.to_s.start_with?("__") }
              clear_capture = if cursor + run == characters.length
                                run.odd?
                              else
                                run.even?
                              end
              state.delete_if { |key, _value| key.is_a?(Integer) } if clear_capture
              return [[boundary, state]]
            end
          end
        end

        if quantifier.kind == :* && fixed_repeated_suffix_width(quantifier, parts.drop(1))
          suffix_width = fixed_repeated_suffix_width(quantifier, parts.drop(1))
          run = quantified_atom_run_length(quantifier.expression, characters, cursor, flags)
          return unless run >= quantifier.minimum

          boundary = (run + suffix_width - 1) / 2
          results = node_results(body, characters, cursor, captures, flags)
          target = results.find { |length, _state| length == boundary + 1 }
          if target
            state = target.last.dup
            state.delete_if { |key, _value| key.is_a?(Symbol) && key.to_s.start_with?("__") }
            return [[boundary, state]]
          end
        end

        nullable_wildcard_suffix = wildcard_node?(quantifier.expression) && suffix_minimum&.zero? &&
                                   suffix_can_consume?(parts.drop(1))
        if quantifier.kind == :* && (suffix_minimum&.positive? || nullable_wildcard_suffix)
          suffix_width = fixed_suffix_width(parts.drop(1)) || suffix_minimum
          suffix_width = 1 if suffix_width&.zero?
          if suffix_width&.positive?
            return absence_bounded_probe_results(
              body, characters, cursor, captures, flags,
              preserve_failed_capture: preserve_quantifier_capture?(quantifier, parts, characters,
                                                                    cursor, flags)
            )
          end
        end

        if quantifier.kind == :* && parts.length == 2 && wildcard_node?(parts[1])
          run = quantified_atom_run_length(quantifier.expression, characters, cursor, flags)
          if run.positive? && cursor + run < characters.length &&
             !quantified_atom_matches?(quantifier.expression, characters, cursor + run, flags)
            boundary = (run + 1) / 2
            results = node_results(body, characters, cursor, captures, flags)
            target = results.find { |length, _state| length == boundary + 1 }
            if target
              state = target.last.dup
              state.delete_if { |key, _value| key.is_a?(Symbol) && key.to_s.start_with?("__") }
              return [[boundary, state]]
            end
          end
        end

        return unless quantifier.kind == :*

        maximum = quantified_absence_length(quantifier, characters, cursor)
        return unless maximum&.positive?

        results = node_results(body, characters, cursor, captures, flags)
        target = results.find { |length, _state| length == maximum + 1 }
        return unless target

        state = target.last.dup
        state.delete_if { |key, _value| key.is_a?(Symbol) && key.to_s.start_with?("__") }
        [[maximum, state]]
      end

      # Execute the two loops used by Onigmo's OP_ABSENT protocol.
      # Each probe uses the current absent end as its input boundary.
      def absence_bounded_probe_results(body, characters, cursor, captures, flags, preserve_failed_capture: false)
        frame = AbsentFrame.new(
          absent_start: cursor,
          absent_end: characters.length,
          probe_position: cursor,
          possible_points: [],
          body_checkpoints: [],
          capture_checkpoints: []
        )
        current_captures = captures
        position = cursor
        while position < frame.absent_end
          frame.probe_position = position
          bounded = characters[0...frame.absent_end]
          results = node_results(body, bounded, position, captures, flags)
          record_absence_checkpoint(frame, position, results, captures)
          if results.empty?
            current_captures = nil unless preserve_failed_capture
          else
            length, state = results.first
            state = state.dup
            state[:__match_probe] = position
            prior_ambiguous = frame.capture_checkpoints.any? { |checkpoint| checkpoint[4] }
            discard_capture = repeat_capture_discard_required?(body, results, state, length,
                                                               prior_ambiguous)
            frame.capture_checkpoints << [position, length, state.dup, discard_capture,
                                          results.length > 1]
            boundary = if length.zero? && nested_nullable_repeat_body?(body)
                         position
                       else
                         position + length - 1
                       end
            frame.absent_end = [frame.absent_end, boundary].min
            current_captures = state
          end
          position += 1
        end

        state = (current_captures || captures).dup
        state.delete_if { |key, _value| key.is_a?(Integer) } if frame.capture_checkpoints.last&.fetch(3) && !bounded_wrapper_capture?(body)
        state.delete_if { |key, _value| key.is_a?(Symbol) && key.to_s.start_with?("__") }
        [[frame.absent_end - cursor, state]]
      end

      # OP_ABSENT_END restores a repeat frame after a body candidate fails.
      # A one-character suffix after an even repeat count is restored to the
      # frame entry. Multiple body candidates restore the ambiguous suffix
      # frame as a whole. The checkpoint stores this VM decision.
      def repeat_capture_discard_required?(body, results, state, length, prior_ambiguous)
        parts = absence_sequence_parts(body)
        quantifier = parts.first
        return false unless parts.length > 1 &&
                            quantifier.is_a?(SemanticBytecode::Quantifier)
        return false unless quantifier.maximum.nil? && %i[* +].include?(quantifier.kind)

        spans = state.values.filter_map do |value|
          value if value.is_a?(Array) && value.length == 2
        end
        return false if spans.empty?

        suffix_starts_with_atom = parts.drop(1).any? do |part|
          node_starts_with_selected_atom?(part, quantifier.expression, state)
        end

        repeat_count = spans.map { |start, finish| length - (finish - start) }.min
        if quantifier.kind == :*
          return repeat_count && repeat_count > 1 && repeat_count.odd? &&
                 spans.any? { |start, finish| finish - start == 1 }
        end

        return true if !prior_ambiguous && repeat_count && repeat_count > 1 &&
                       spans.any? { |start, finish| finish - start == 1 }
        return true if repeat_count&.positive? && repeat_count.even? && spans.any? do |start, finish|
          finish - start == 1
        end

        results.length > 1 && spans.any? { |start, finish| finish - start > 1 } &&
          suffix_starts_with_atom
      end

      # A repeat frame restores captures when its failed suffix crosses an
      # even number of iterations. Wildcard repeats use the outer frame.
      def preserve_quantifier_capture?(quantifier, parts, characters, cursor, flags)
        return false if wildcard_node?(quantifier.expression)
        return false unless fixed_suffix_width(parts.drop(1)).nil?
        return true unless quantifier.kind == :*

        quantified_atom_run_length(quantifier.expression, characters, cursor, flags).odd?
      end

      def repeated_quantified_atom_suffix?(quantifier, suffix)
        quantified_atoms_equivalent?(quantifier.expression, suffix)
      end

      def fixed_repeated_suffix_width(quantifier, suffix_parts)
        return if suffix_parts.empty?
        return unless suffix_parts.all? { |part| quantified_atoms_equivalent?(quantifier.expression, part) }

        values = suffix_parts.map { |part| literal_value(part) }
        return unless values.all?

        values.sum(&:length)
      end

      def fixed_suffix_width(parts)
        return if parts.empty?

        widths = parts.map { |part| static_node_width(part) }
        return unless widths.all?

        widths.sum
      end

      def minimum_suffix_width(parts)
        widths = parts.map { |part| minimum_node_width(part) }
        return unless widths.all?

        widths.sum
      end

      def minimum_node_width(node)
        case node
        when SemanticBytecode::Literal
          node.value.length
        when SemanticBytecode::CharacterClass, SemanticBytecode::Any,
             SemanticBytecode::Escape, SemanticBytecode::Property
          1
        when SemanticBytecode::Group, SemanticBytecode::OptionGroup,
             SemanticBytecode::AtomicGroup
          minimum_node_width(node.body)
        when SemanticBytecode::Sequence
          minimum_suffix_width(node.parts)
        when SemanticBytecode::Alternation
          widths = node.branches.map { |branch| minimum_node_width(branch) }
          widths.min if widths.all?
        when SemanticBytecode::Quantifier
          width = minimum_node_width(node.expression)
          width && width * node.minimum.to_i
        end
      end

      def suffix_can_consume?(parts)
        parts.any? { |part| node_can_consume?(part) }
      end

      def node_can_consume?(node)
        case node
        when SemanticBytecode::Literal
          !node.value.empty?
        when SemanticBytecode::CharacterClass, SemanticBytecode::Any,
             SemanticBytecode::Escape, SemanticBytecode::Property
          true
        when SemanticBytecode::Group, SemanticBytecode::OptionGroup,
             SemanticBytecode::AtomicGroup
          node_can_consume?(node.body)
        when SemanticBytecode::Sequence
          node.parts.any? { |part| node_can_consume?(part) }
        when SemanticBytecode::Alternation
          node.branches.any? { |branch| node_can_consume?(branch) }
        when SemanticBytecode::Quantifier
          node.maximum != 0 && node_can_consume?(node.expression)
        else
          false
        end
      end

      def static_node_width(node)
        case node
        when SemanticBytecode::Literal
          node.value.length
        when SemanticBytecode::CharacterClass, SemanticBytecode::Any,
             SemanticBytecode::Escape, SemanticBytecode::Property
          1
        when SemanticBytecode::Group, SemanticBytecode::OptionGroup,
             SemanticBytecode::AtomicGroup
          static_node_width(node.body)
        when SemanticBytecode::Sequence
          fixed_suffix_width(node.parts)
        when SemanticBytecode::Alternation
          widths = node.branches.map { |branch| static_node_width(branch) }
          widths.first if widths.all? && widths.uniq.one?
        when SemanticBytecode::Quantifier
          return unless node.maximum && node.minimum == node.maximum

          width = static_node_width(node.expression)
          width && width * node.minimum
        end
      end

      def wildcard_node?(node)
        node.is_a?(SemanticBytecode::Any)
      end

      def quantified_atoms_equivalent?(left, right)
        return quantified_atoms_equivalent?(left, right.expression) if
          right.is_a?(SemanticBytecode::Quantifier)

        left == right || (literal_value(left) && literal_value(left) == literal_value(right))
      end

      def discard_failed_quantified_suffix_captures(body, characters, cursor, captures, flags)
        parts = absence_sequence_parts(body)
        quantifier = parts.first
        return captures unless parts.length > 1 && quantifier.is_a?(SemanticBytecode::Quantifier)
        return captures unless quantifier.kind == :+ && quantifier.maximum.nil?

        probe = captures[:__match_probe] || cursor
        run = quantified_atom_run_length(quantifier.expression, characters, probe, flags)
        suffix_starts_with_atom = parts.drop(1).any? do |part|
          node_starts_with_selected_atom?(part, quantifier.expression, captures)
        end
        repeated_atom_capture = captures.values.any? do |value|
          value.is_a?(Array) && value.length == 2 && value[1] - value[0] == 1 &&
            run > 1 && value[0] == probe + run
        end
        return captures.reject { |key, _value| key.is_a?(Integer) } if repeated_atom_capture
        return captures unless suffix_starts_with_atom
        return captures unless captures.values.any? do |value|
          next false unless value.is_a?(Array) && value.length == 2

          span = value[1] - value[0]
          (run.positive? && (span > 1 || (value[1] == characters.length && run.odd?))) ||
          (span > 1 && value[1] == characters.length) ||
          (run > 1 && span == 1 && value[0] == probe + run)
        end

        captures.reject { |key, _value| key.is_a?(Integer) }
      end

      def filter_nested_quantifier_suffix_captures(body, captures, characters, flags)
        outer = absence_sequence_parts(body).first
        return captures unless outer.is_a?(SemanticBytecode::Group)

        nested = absence_sequence_parts(outer.body)
        quantifier = nested.first
        return captures unless nested.length > 1 &&
                               quantifier.is_a?(SemanticBytecode::Quantifier)

        outer_span = captures[outer.number]
        suffix_width = minimum_suffix_width(nested.drop(1))
        if outer_span.is_a?(Array) && suffix_width
          repeat_end = outer_span[1] - suffix_width
          repetitions = quantifier_repetition_count(
            quantifier.expression, characters, outer_span[0], repeat_end, flags
          )
          return {} if repetitions > 1
        end

        hidden = capture_numbers(quantifier.expression)
        captures.reject { |key, _value| key.is_a?(Integer) && hidden.include?(key) }
      end

      def quantifier_repetition_count(expression, characters, start, finish, flags)
        position = start
        count = 0
        while position < finish
          length = node_results(expression, characters, position, {}, flags)
                   .map(&:first).select(&:positive?).min
          break unless length && position + length <= finish

          position += length
          count += 1
        end
        position == finish ? count : 0
      end

      def quantifier_repetition_path_count(expression, characters, start, finish, flags)
        memo = {}
        minimum_count = lambda do |position|
          return 0 if position == finish
          return memo[position] if memo.key?(position)

          counts = node_results(expression, characters, position, {}, flags).filter_map do |length, _state|
            next unless length.positive? && position + length <= finish

            tail = minimum_count.call(position + length)
            tail.zero? && position + length != finish ? nil : tail + 1
          end
          memo[position] = counts.min || 0
        end

        minimum_count.call(start)
      end

      def capture_numbers(node)
        case node
        when SemanticBytecode::Group
          node.number ? [node.number] + capture_numbers(node.body) : capture_numbers(node.body)
        when SemanticBytecode::Sequence
          node.parts.flat_map { |part| capture_numbers(part) }
        when SemanticBytecode::Alternation
          node.branches.flat_map { |branch| capture_numbers(branch) }
        when SemanticBytecode::Quantifier
          capture_numbers(node.expression)
        else
          []
        end
      end

      def capture_names(node)
        case node
        when SemanticBytecode::Group
          names = node.name ? [node.name] : []
          names + capture_names(node.body)
        when SemanticBytecode::Sequence
          node.parts.flat_map { |part| capture_names(part) }
        when SemanticBytecode::Alternation
          node.branches.flat_map { |branch| capture_names(branch) }
        when SemanticBytecode::Quantifier
          capture_names(node.expression)
        else
          []
        end
      end

      def absence_only_node?(node)
        node = node.parts.first if node.is_a?(SemanticBytecode::Sequence) && node.parts.one?
        node.is_a?(SemanticBytecode::Absence)
      end

      def adjust_possessive_absence_capture(expression, cursor, length, captures)
        return captures unless expression.is_a?(SemanticBytecode::Group) &&
                               absence_only_node?(expression.body)

        adjusted = captures.dup
        span = [cursor + length, cursor + length]
        adjusted[expression.number] = span if expression.capture
        adjusted[expression.name] = span if expression.capture && expression.name
        adjusted
      end

      def discard_absence_body_captures(node, captures)
        numbers = capture_numbers(node.body)
        names = capture_names(node.body)
        return captures if numbers.empty? && names.empty?

        discarded = captures.select do |key, _value|
          numbers.include?(key) || names.include?(key)
        end
        return captures if discarded.empty?

        visible = captures.reject { |key, _value| discarded.key?(key) }
        hidden = visible.delete(:__absence_captures) || {}
        visible[:__absence_captures] = hidden.merge(discarded)
        visible
      end

      def clear_repeated_absence_captures(node, captures)
        body = node
        body = body.body if body.is_a?(SemanticBytecode::Group)
        return captures unless body.is_a?(SemanticBytecode::Absence)

        cleaned = captures.dup
        capture_numbers(body.body).each { |number| cleaned.delete(number) }
        cleaned
      end

      def node_starts_with_selected_atom?(node, atom, captures)
        case node
        when SemanticBytecode::Group, SemanticBytecode::OptionGroup,
             SemanticBytecode::AtomicGroup
          node_starts_with_selected_atom?(node.body, atom, captures)
        when SemanticBytecode::Sequence
          node.parts.any? && node_starts_with_selected_atom?(node.parts.first, atom, captures)
        when SemanticBytecode::Alternation
          index = captures[:__match_alternative_index]
          branch = index.is_a?(Integer) ? node.branches[index] : node.branches.first
          branch && node_starts_with_selected_atom?(branch, atom, captures)
        when SemanticBytecode::Literal
          quantified_atoms_equivalent?(node, atom)
        else
          false
        end
      end

      def quantified_atom_run_length(expression, characters, cursor, flags)
        atom = literal_value(expression)
        return 0 if atom && atom.empty?

        position = cursor
        if atom
          position += atom.length while characters[position, atom.length].join == atom
        else
          position += 1 while node_results(expression, characters, position, {}, flags).any? { |length, _state| length == 1 }
        end
        position - cursor
      end

      def quantified_atom_matches?(expression, characters, position, flags)
        atom = literal_value(expression)
        return characters[position, atom.length].join == atom if atom

        node_results(expression, characters, position, {}, flags).any? { |length, _state| length == 1 }
      end

      def contains_absence_node?(node)
        case node
        when SemanticBytecode::Absence
          true
        when SemanticBytecode::Sequence
          node.parts.any? { |part| contains_absence_node?(part) }
        when SemanticBytecode::Alternation
          node.branches.any? { |branch| contains_absence_node?(branch) }
        when SemanticBytecode::Group, SemanticBytecode::Quantifier,
             SemanticBytecode::OptionGroup, SemanticBytecode::AtomicGroup
          child = node.respond_to?(:body) ? node.body : node.expression
          contains_absence_node?(child)
        else
          false
        end
      end

      def absence_sequence_parts(node)
        loop do
          if node.is_a?(SemanticBytecode::Group) && !node.capture
            node = node.body
          elsif node.is_a?(SemanticBytecode::Sequence)
            only = node.parts.one? && node.parts.first
            if only.is_a?(SemanticBytecode::Group) && !only.capture
              node = only.body
              next
            end
            return node.parts
          else
            return [node]
          end
        end
      end

      def sequence_failure_state(body, characters, cursor, captures, flags)
        loop do
          if body.is_a?(SemanticBytecode::Group) && !body.capture
            body = body.body
          elsif body.is_a?(SemanticBytecode::Sequence)
            only = body.parts.one? && body.parts.first
            body = only.body if only.is_a?(SemanticBytecode::Group) && !only.capture
            break
          else
            return
          end
        end
        return unless body.is_a?(SemanticBytecode::Sequence)

        states = [[0, captures]]
        body.parts.each do |part|
          next_states = states.flat_map do |consumed, state|
            node_results(part, characters, cursor + consumed, state, flags).map do |length, inner|
              [consumed + length, inner]
            end
          end
          return states.max_by(&:first)&.then { |consumed, state| [state, cursor + consumed] } if next_states.empty?

          states = next_states
        end
        nil
      end

      def zero_width_absence_results(body, characters, cursor, captures, flags)
        positions = []
        position_states = {}
        has_consuming_match = false
        cursor.upto(characters.length) do |position|
          results = node_results(body, characters, position, captures, flags)
          zero_width = results.find do |length, state|
            length.zero? && (state[:__match_start] || position) == position
          end
          if zero_width
            positions << position
            position_states[position] = zero_width.last
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
        first_zero_state = position_states[positions.first] if contains_positive_lookahead?(body)
        state = (position_states[start] || position_states[finish] || first_zero_state || captures).dup
        state = captures.dup unless contains_assertion?(body)
        state = captures.dup if state.keys.count { |key| key.is_a?(Integer) } > 1
        if finish == characters.length && !contains_positive_lookahead?(body)
          state.delete_if do |key, value|
            key.is_a?(Integer) && value.is_a?(Array) && value[0] == value[1]
          end
        end
        state = filter_nested_absence_captures(body, state)
        state = filter_absence_capture_scope(body, state)
        if start != cursor
          state[:__match_start] = start
          state[:__match_end] = finish
          state[:__match_probe] = characters[start - 1] if start.positive?
        end
        results = [[finish - start, state]]
        # Keep the zero-length probe as a backtracking candidate. A following
        # bytecode operand can match at the absence start before the first
        # forbidden zero-width body position.
        if start == cursor && finish > start
          (finish - start - 1).downto(1) { |length| results << [length, captures.dup] }
          results << [0, captures.dup]
        end
        results
      end

      def contains_assertion?(node)
        case node
        when SemanticBytecode::Assertion
          true
        when SemanticBytecode::Sequence
          node.parts.any? { |part| contains_assertion?(part) }
        when SemanticBytecode::Alternation
          node.branches.any? { |branch| contains_assertion?(branch) }
        when SemanticBytecode::Group, SemanticBytecode::Quantifier,
             SemanticBytecode::OptionGroup, SemanticBytecode::AtomicGroup,
             SemanticBytecode::Absence
          child = node.respond_to?(:body) ? node.body : node.expression
          contains_assertion?(child)
        else
          false
        end
      end

      def contains_positive_lookahead?(node)
        case node
        when SemanticBytecode::Assertion
          %i[positive positive_lookahead].include?(node.kind)
        when SemanticBytecode::Sequence
          node.parts.any? { |part| contains_positive_lookahead?(part) }
        when SemanticBytecode::Alternation
          node.branches.any? { |branch| contains_positive_lookahead?(branch) }
        when SemanticBytecode::Group, SemanticBytecode::Quantifier,
             SemanticBytecode::OptionGroup, SemanticBytecode::AtomicGroup,
             SemanticBytecode::Absence
          child = node.respond_to?(:body) ? node.body : node.expression
          contains_positive_lookahead?(child)
        else
          false
        end
      end

      def zero_width_quantifier_absence?(body, characters, cursor, flags = {})
        sequence = if body.is_a?(SemanticBytecode::Sequence)
                     body.parts
                   else
                     [body]
                   end
        return false unless sequence.length == 1

        quantifier = sequence.first
        return false unless quantifier.is_a?(SemanticBytecode::Quantifier)
        return false unless quantifier.maximum.nil?
        return false unless quantifier.kind == :* || (flags[:ignorecase] && quantifier.kind == :"?")

        literal = literal_value(quantifier.expression)
        return false unless literal && !literal.empty? && cursor < characters.length

        if flags[:ignorecase]
          return node_results(body, characters, cursor, {}, flags).none? do |length, _state|
            length.positive?
          end
        end

        characters[cursor, literal.length].join != literal
      end

      def captureless_absence_body?(body)
        parts = if body.is_a?(SemanticBytecode::Sequence)
                  body.parts
                else
                  [body]
                end
        parts.length == 1 &&
          parts.first.is_a?(SemanticBytecode::Quantifier)
      end

      def adjust_nested_repeat_capture(body, captures, length, cursor)
        return captures unless length

        parts = body.is_a?(SemanticBytecode::Sequence) ? body.parts : [body]
        outer = parts.first
        return captures unless parts.length == 1 &&
                               outer.is_a?(SemanticBytecode::Group)

        nested = outer.body
        nested_parts = nested.is_a?(SemanticBytecode::Sequence) ? nested.parts : [nested]
        quantifier = nested_parts.first
        return captures unless nested_parts.length == 1 &&
                               quantifier.is_a?(SemanticBytecode::Quantifier)

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
          width = repetitions.even? ? [repetitions, 2].min : 1
          start = cursor + ((repetitions - 1) / 2)
          adjusted[outer.number] = [start, start + width] if repetitions.positive?
        elsif repetitions.even?
          adjusted.delete(outer.number)
        else
          start = cursor + ((repetitions - 1) / 2) * unit.length
          adjusted[outer.number] = [start, start + unit.length]
        end
        adjusted
      end

      def filter_nested_absence_captures(body, captures)
        parts = body.is_a?(SemanticBytecode::Sequence) ? body.parts : [body]
        outer = parts.first
        return captures unless parts.length == 1 &&
                               outer.is_a?(SemanticBytecode::Group)

        nested = outer.body
        nested_parts = nested.is_a?(SemanticBytecode::Sequence) ? nested.parts : [nested]
        quantifier = nested_parts.first
        return captures unless nested_parts.length == 1 &&
                               quantifier.is_a?(SemanticBytecode::Quantifier)

        expression = quantifier.expression
        return captures unless expression.is_a?(SemanticBytecode::Group)

        captures.select { |key, _value| key == outer.number }
      end

      def filter_absence_capture_scope(body, captures)
        # A backreference-only body defines no capture scope. Preserve the
        # incoming local state so the body can read captures from its prefix.
        return captures if capture_numbers(body).empty?

        scope = body
        loop do
          if scope.is_a?(SemanticBytecode::Group) && !scope.capture
            scope = scope.body
          elsif scope.is_a?(SemanticBytecode::Sequence)
            only = scope.parts.one? && scope.parts.first
            break unless only.is_a?(SemanticBytecode::Group)
            break if only.capture

            scope = only.body
          else
            break
          end
        end
        parts = scope.is_a?(SemanticBytecode::Sequence) ? scope.parts : [scope]
        direct_group = parts.any? do |part|
          part.is_a?(SemanticBytecode::Group) && part.capture
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

      def quantified_absence_length(body, characters, cursor, flags = {})
        sequence = if body.is_a?(SemanticBytecode::Sequence)
                     body.parts
                   else
                     [body]
                   end
        return unless sequence.length == 1

        if sequence.first.is_a?(SemanticBytecode::Group)
          nested = sequence.first.body
          nested_parts = (nested.parts if nested.is_a?(SemanticBytecode::Sequence))
          return quantified_absence_length(nested, characters, cursor, flags) if nested_parts&.length == 1
        end

        quantifier = sequence.first
        return unless quantifier.is_a?(SemanticBytecode::Quantifier)
        return unless quantifier.maximum.nil?
        return unless %i[+ *].include?(quantifier.kind) || quantifier.minimum.to_i >= 2

        literal = literal_value(quantifier.expression)
        if flags[:ignorecase] && literal && !literal.empty?
          run = 0
          position = cursor
          while position < characters.length
            length = node_results(quantifier.expression, characters, position, {}, flags).map(&:first).select(&:positive?).max
            break unless length

            run += length
            position += length
          end
          return if run.zero?
          return if quantifier.minimum.to_i.positive? && run < quantifier.minimum

          return quantifier.minimum.to_i >= 2 ? (run + quantifier.minimum - 1) / 2 : run / 2
        end
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
        elsif quantifier.expression.is_a?(SemanticBytecode::CharacterClass)
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
                   when SemanticBytecode::Alternation
                     node.branches
                   when SemanticBytecode::Group
                     return alternation_unit(node.body)
                   when SemanticBytecode::Sequence
                     return alternation_unit(node.parts.first) if node.parts.length == 1
                   end
        return unless branches && !branches.empty?

        values = branches.map { |branch| literal_value(branch) }
        return unless values.all? && values.map(&:length).uniq.one?

        values.first
      end

      def variable_alternation_units(node)
        body = if node.is_a?(SemanticBytecode::Group)
                 node.body
               elsif node.is_a?(SemanticBytecode::Sequence)
                 node.parts.length == 1 ? node.parts.first : node
               else
                 node
               end
        branches = (body.branches if body.is_a?(SemanticBytecode::Alternation))
        return unless branches

        values = branches.map { |branch| literal_value(branch) }
        return unless values.all? && values.map(&:length).uniq.length > 1

        values
      end

      def class_match_lengths(node, characters, cursor, flags)
        return [] unless cursor < characters.length

        lengths = []
        character = characters[cursor]
        casefold_source = flags[:ignorecase] && !node.value.start_with?("^") &&
                          !node.value.include?("[") && !node.value.include?(":") &&
                          !node.value.include?("&&") && !node.value.include?("\\")
        direct_casefold = node.value.each_char.any? { |candidate| candidate.downcase(:fold).length == 1 }
        lengths << 1 if !flags[:lookbehind_casefold] || !casefold_source || direct_casefold
        if lengths.any?
          lengths.select! do
            class_match?(node, character, flags)
          end
        end
        if casefold_source
          node.value.each_char do |candidate|
            casefold_lengths(candidate, characters, cursor,
                             expanded_only: flags[:lookbehind_casefold]).each do |length|
              lengths << length unless lengths.include?(length)
            end
          end
        end
        if flags[:ignorecase] && !node.value.start_with?("^")
          Array(node.casefolds).each do |_source, folded|
            next if node.value.include?("[:") && folded.ascii_only? && !flags[:full_casefold]

            width = folded.length
            slice = characters[cursor, width]
            next unless slice && slice.length == width

            candidate = slice.join
            next unless casefold_equal?(folded, candidate)

            lengths << width unless lengths.include?(width)
          end
        end
        lengths
      rescue RangeError, ArgumentError
        lengths
      end

      def class_match?(node, character, flags)
        matched = Onibi::ClassPredicates.matches?(node.value, character,
                                                  ignorecase: flags[:ignorecase],
                                                  encoding: flags[:encoding])
        return true if matched
        return false unless flags[:ignorecase]
        return false if node.value.start_with?("^")
        return false if node.value.include?("[") || node.value.include?(":") || node.value.include?("\\")

        folded = character.downcase(:fold)
        return false unless folded.each_char.one?

        Onibi::ClassPredicates.matches?(node.value, folded,
                                        ignorecase: true,
                                        encoding: flags[:encoding])
      end

      def boundary_word?(character, encoding = nil)
        return Onibi::CharacterPredicates.word?(character) if character.encoding == Encoding::ASCII_8BIT
        return true if encoding && [Encoding::EUC_JP, Encoding::Windows_31J].include?(encoding) && !character.ascii_only?

        Onibi::UnicodeProperties.boundary_word?(unicode_character(character))
      end

      # Returns the number of characters in one extended grapheme cluster.
      # The bytecode escape consumes one cluster, not one codepoint. Combining
      # marks, variation selectors, emoji modifiers, and ZWJ joins stay local
      # to this transition, so the VM does not need AST state at runtime.
      def grapheme_cluster_length(characters, cursor)
        grapheme_cluster_lengths(characters, cursor)&.first
      end

      def grapheme_cluster_lengths(characters, cursor)
        return nil if cursor >= characters.length
        return [2] if characters[cursor] == "\r" && characters[cursor + 1] == "\n"
        return [1] if grapheme_control?(characters[cursor])
        return [2] if regional_indicator?(characters[cursor]) && regional_indicator?(characters[cursor + 1])

        position = cursor + 1
        alternatives = []
        loop do
          position += 1 while position < characters.length && grapheme_extension?(characters[position])
          break unless position < characters.length && characters[position] == "\u200D"

          position += 1
          break if position >= characters.length ||
                   !grapheme_zwj_target?(characters[position], characters[position - 2],
                                         position - 3 >= cursor ? characters[position - 3] : nil,
                                         characters[cursor])

          alternatives << position - cursor if grapheme_extension?(characters[cursor])
          position += 1
        end
        ([position - cursor] + alternatives).uniq.sort.reverse
      end

      def grapheme_extension?(character)
        return false unless character

        codepoint = character.codepoints.first
        Onibi::UnicodeProperties.mark?(unicode_character(character)) ||
          (0x900..0x90F).cover?(codepoint) ||
          codepoint == 0x94D || (0x9BC..0x9CD).cover?(codepoint) ||
          codepoint.between?(0xFE00, 0xFE0F) || codepoint.between?(0xE0100, 0xE01EF) ||
          codepoint.between?(0x1F3FB, 0x1F3FF)
      end

      def grapheme_zwj_target?(character, preceding, base, root)
        codepoint = character.codepoints.first
        preceding_codepoint = preceding&.codepoints&.first
        root_codepoint = root&.codepoints&.first
        emoji_target = codepoint.between?(0x1F000, 0x1FAFF) || codepoint.between?(0x2600, 0x27BF)
        emoji_context = [preceding_codepoint, base&.codepoints&.first, root_codepoint].compact.any? do |value|
          value.between?(0x1F000, 0x1FAFF) || value.between?(0x2600, 0x27BF) ||
            value.between?(0x1F3FB, 0x1F3FF)
        end
        indic = codepoint.between?(0x0900, 0x0DFF) || codepoint.between?(0x0F00, 0x109F)
        repeated_zwj = codepoint == 0x200D && preceding_codepoint == 0x200D
        grapheme_extension?(character) || repeated_zwj || (emoji_target && emoji_context) ||
          (indic && indic_base?(base) && grapheme_extension?(preceding))
      end

      def indic_base?(character)
        return false unless character

        codepoint = character.codepoints.first
        codepoint.between?(0x0900, 0x0DFF) || codepoint.between?(0x0F00, 0x109F)
      end

      def regional_indicator?(character)
        character && character.codepoints.first.between?(0x1F1E6, 0x1F1FF)
      end

      def grapheme_control?(character)
        codepoint = character.codepoints.first
        codepoint <= 0x1F || codepoint.between?(0x7F, 0x9F)
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
        when SemanticBytecode::Literal then node.value
        when SemanticBytecode::Group then literal_value(node.body)
        when SemanticBytecode::Sequence
          node.parts.map { |part| literal_value(part) }.then { |values| values.all? ? values.join : nil }
        end
      end

      def casefold_equal?(left, right)
        left.downcase(:fold) == right.downcase(:fold)
      end

      def simple_casefold_equal?(left, right)
        left.downcase == right.downcase
      end

      def casefold_lengths(value, characters, cursor, folded: nil, expanded_only: false)
        folded_value = folded || value.downcase(:fold)
        maximum = folded_value.length
        minimum = expanded_only && maximum > value.length ? value.length + 1 : 1
        (minimum..maximum).select do |length|
          slice = characters[cursor, length]
          next false unless slice && slice.length == length

          folded_value == slice.join.encode(Encoding::UTF_8).downcase(:fold)
        end
      end

      def property_matches?(name, character, ignorecase, encoding = nil)
        non_unicode_encoding = encoding && ![Encoding::UTF_8, Encoding::US_ASCII].include?(encoding)
        incompatible = ascii_property?(name) && (name != "Word" || encoding == Encoding::ASCII_8BIT)
        return :incompatible if non_unicode_encoding && incompatible && !character.ascii_only?
        return true if name == "Word" && non_unicode_encoding && encoding != Encoding::ASCII_8BIT &&
                       !character.ascii_only?

        normalized = Onibi::UnicodeProperties.normalize_name(name)
        normalized_character = if name == "Word" && non_unicode_encoding && encoding != Encoding::ASCII_8BIT &&
                                  !character.ascii_only?
                                 character.encode(Encoding::UTF_8)
                               else
                                 character
                               end
        return true if Onibi::UnicodeProperties.matches_normalized?(normalized, normalized_character)
        return false unless ignorecase && normalized != "ASCII"

        Onibi::UnicodeProperties.casefold_matches?(normalized, normalized_character)
      rescue EncodingError
        false
      end

      def ascii_property?(name)
        %w[ASCII Alpha Alnum Digit Lower Upper Space Word XDigit Blank Cntrl Graph Print Punct].include?(name)
      end

      def unicode_character(character)
        character.encoding == Encoding::UTF_8 ? character : character.encode(Encoding::UTF_8)
      rescue EncodingError
        character
      end
    end
  end
end
