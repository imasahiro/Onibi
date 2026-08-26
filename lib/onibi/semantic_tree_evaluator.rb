# frozen_string_literal: true

module Onibi
  module Interpreter
    # rubocop:disable Metrics/ModuleLength
    # Compatibility evaluator for semantic forms that cannot yet be lowered
    # to flat VM instructions. The flat executor never includes this module.
    module SemanticTreeEvaluator
      # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
      def tree_results(node, characters, cursor, captures, flags = {})
        raise "flat VM entered the compatibility tree evaluator" if instance_variable_defined?(:@flat_program) && @flat_program

        @state.steps += 1
        return [] if @state.steps > 2_000_000

        # A captured expanded fold that matched its source code point cannot
        # split before a normal consuming operand. MRI permits the split only
        # when the next operand is an alternation, whose bytecode carries its
        # own fold-boundary policy.

        expanded_source = captures[:__expanded_literal_source]
        grouped_expanded_source = captures[:__group_expanded_literal_source]
        operand_fold = expanded_fold_operand_value(node)
        boundary_node = !operand_fold.nil?
        deferred_group_fold = nil
        if (expanded_source || grouped_expanded_source) && node.is_a?(SemanticBytecode::Quantifier)
          captures = captures.dup
          captures.delete(:__expanded_literal_source)
          captures.delete(:__expanded_literal_fold)
          captures.delete(:__expanded_literal_boundary)
          captures.delete(:__group_expanded_literal_source)
          captures.delete(:__group_expanded_literal_fold)
          captures.delete(:__group_expanded_literal_boundary)
          captures.delete(:__group_expanded_literal_prefix)
          expanded_source = false
          grouped_expanded_source = false
        end
        expanded_marker_boundary = node.is_a?(SemanticBytecode::Literal) || simple_group_literal_node?(node)
        if expanded_source && (expanded_marker_boundary || captures[:__expanded_literal_from_class])
          captures = captures.dup
          captures.delete(:__expanded_literal_source)
          captures.delete(:__expanded_literal_from_class)
          captures[:__group_expanded_literal_source] = true
          captures[:__group_expanded_literal_fold] ||= captures[:__expanded_literal_fold]
          captures[:__group_expanded_literal_boundary] ||= captures[:__expanded_literal_boundary]
          captures[:__group_expanded_literal_value] ||= captures[:__expanded_literal_value]
          captures.delete(:__expanded_literal_fold)
          captures.delete(:__expanded_literal_boundary)
          captures.delete(:__expanded_literal_value)
          grouped_expanded_source = true
        end
        if grouped_expanded_source && node.is_a?(SemanticBytecode::Literal) &&
           captures[:__group_expanded_literal_fold] == node.value
          captures = captures.dup
          captures.delete(:__group_expanded_literal_source)
          captures.delete(:__group_expanded_literal_fold)
          captures.delete(:__group_expanded_literal_boundary)
          captures.delete(:__group_expanded_literal_prefix)
          grouped_expanded_source = false
        end
        if grouped_expanded_source && boundary_node
          source_fold = captures[:__group_expanded_literal_fold]
          prefix = captures[:__group_expanded_literal_prefix] || +""
          combined = prefix + operand_fold.to_s
          if (captures[:__captured_expanded_fold] || captures[:__expanded_fold]) &&
             captures[:__fold_alternation_operand] &&
             source_fold && !source_fold.start_with?(combined)
            captures = captures.dup
            captures[:__captured_fold_incompatible] = true
          end
          if (captures[:__captured_expanded_fold] || captures[:__expanded_fold]) &&
             captures[:__fold_alternation_operand] && cursor + 1 >= characters.length &&
             source_fold&.start_with?(combined) && combined != source_fold
            return []
          end

          if source_fold && combined == source_fold
            if !(captures[:__fold_alternation_operand] &&
                   captures[:__group_expanded_literal_value] == characters[cursor]) && captures[:__group_expanded_literal_boundary]
              return []
            end

            captures = captures.dup
            captures.delete(:__group_expanded_literal_source)
            captures.delete(:__group_expanded_literal_fold)
            captures.delete(:__group_expanded_literal_boundary)
            captures.delete(:__group_expanded_literal_prefix)
            captures.delete(:__group_expanded_literal_value)
            grouped_expanded_source = false
          end

          if grouped_expanded_source && captures[:__group_expanded_literal_boundary] &&
             node.is_a?(SemanticBytecode::Literal) && source_fold &&
             !captures[:__fold_alternation_context] && !captures[:__fold_lookahead_operand] &&
             (!captures[:__fold_alternation_operand] || cursor + 1 >= characters.length) &&
             (captures[:__group_expanded_literal_boundary][:kind] != :simple_fold_source ||
              !captures[:__lookbehind_simple_fold_source]) &&
             !captures[:__optional_fold_zero] &&
             !source_fold.start_with?(combined)
            return []
          end

          captures = captures.dup unless source_fold && combined == source_fold
          if grouped_expanded_source && ((node.is_a?(SemanticBytecode::Group) && !node.capture) ||
             node.is_a?(SemanticBytecode::OptionGroup) || node.is_a?(SemanticBytecode::AtomicGroup)
                                        )
            deferred_group_fold = [source_fold, combined,
                                   captures[:__group_expanded_literal_boundary]]
            captures.delete(:__group_expanded_literal_source)
            captures.delete(:__group_expanded_literal_fold)
            captures.delete(:__group_expanded_literal_boundary)
            captures.delete(:__group_expanded_literal_prefix)
          elsif grouped_expanded_source && source_fold&.start_with?(combined)
            captures[:__group_expanded_literal_prefix] = combined
          elsif grouped_expanded_source
            captures.delete(:__group_expanded_literal_source)
            captures.delete(:__group_expanded_literal_fold)
            captures.delete(:__group_expanded_literal_boundary)
            captures.delete(:__group_expanded_literal_prefix)
          end
        elsif (expanded_source || grouped_expanded_source) && boundary_node
          captures = captures.dup
          captures.delete(:__expanded_literal_source)
          captures.delete(:__expanded_literal_fold)
          captures.delete(:__expanded_literal_boundary)
          captures.delete(:__expanded_literal_from_class)
          captures.delete(:__group_expanded_literal_source)
          captures.delete(:__group_expanded_literal_fold)
          captures.delete(:__group_expanded_literal_boundary)
          captures.delete(:__group_expanded_literal_prefix)
          captures.delete(:__group_expanded_literal_value)
        end

        case node
        when SemanticBytecode::Sequence
          return [] if lookahead_variant_barrier?(node, characters, cursor, flags)
          return [] if expanded_quantifier_anchor_barrier?(node, characters, cursor, flags)
          if node.parts.each_index.any? do |index|
               reverse_fold_optional_barrier?(node.parts[index], node.parts[index + 1],
                                              node.parts[index + 2], characters, cursor, flags)
             end
            return []
          end

          if flags[:ignorecase] && node.parts.all? { |part| part.is_a?(SemanticBytecode::Literal) }
            value = node.parts.map(&:value).join
            first_expands = node.parts.first &&
                            node.parts.first.value.downcase(:fold).length > node.parts.first.value.length
            has_mark = value.each_char.any? { |character| Onibi::UnicodeProperties.mark?(character) }
            reverse_fold = reverse_casefold_sequence?(value)
            folded_value = node.parts.map { |part| part.casefold || part.value }.join
            fold_boundary_sensitive = node.parts.each_cons(2).any? do |left, right|
              left_literal = left.is_a?(SemanticBytecode::Literal)
              right_expands = right.is_a?(SemanticBytecode::Literal) &&
                              (right.casefold || right.value).length > right.value.length
              left_literal && right_expands &&
                (left.casefold.nil? || left.casefold.length == left.value.length)
            end
            if !value.empty? && !fold_boundary_sensitive && (value.ascii_only? || first_expands ||
              has_mark || reverse_fold || folded_value != value)
              folded_length = casefold_lengths(value, characters, cursor,
                                               folded: folded_value,
                                               expanded_only: flags[:lookbehind_casefold] &&
                                                              !flags[:lookbehind_fold_source]).first
              if folded_length
                next_captures = captures.dup
                simple_source = node.parts.length == 1 &&
                                simple_fold_source_match?(node.parts.first, characters[cursor]) &&
                                characters[cursor] != folded_value
                if !flags[:skip_fold_marker] && folded_length == 1 &&
                   characters[cursor]&.downcase(:fold) == folded_value &&
                   (folded_value.length > value.length || simple_source)
                  next_captures[:__expanded_literal_source] = true
                  next_captures[:__expanded_literal_fold] = folded_value
                  next_captures[:__expanded_literal_boundary] = node.parts.filter_map do |part|
                    simple_fold_boundary_for(part, characters[cursor]) || part.fold_boundary
                  end.first
                  next_captures[:__expanded_literal_value] = characters[cursor]
                end
                return [[folded_length, next_captures]]
              end
              return []
            end
          end

          class_repetition = flags[:ignorecase] && flags[:casefold_repetition] &&
                             node.parts.length > 1 &&
                             node.parts.map { |part| repeated_class_operand(part) }.all? &&
                             node.parts.none? { |part| repeated_class_operand(part).value.start_with?("^") } &&
                             node.parts.all? { |part| fold_repetition_class?(repeated_class_operand(part)) } &&
                             (node.parts.all? { |part| repeated_class_operand(part).casefolds.empty? } ||
                              node.parts.all? do |part|
                                operand = repeated_class_operand(part)
                                operand.casefolds.any? && operand.value.each_char.one?
                              end)
          if class_repetition
            class_lengths = casefold_class_sequence_lengths(
              node.parts.map { |part| repeated_class_operand(part) }, characters, cursor, flags
            )
            return class_lengths.map { |length| [length, captures.dup] } unless class_lengths.empty?
          end

          parts = node.parts
          if parts.length == 2 && fold_property_alternation_anchor_expansion?(parts[0], parts[1], characters,
                                                                              cursor)
            expanded_flags = flags.merge(property_alternation_anchor: true)
            first_results = tree_results(parts[0], characters, cursor, captures, expanded_flags)
            maximum = first_results.map(&:first).max
            return first_results.select { |length, _state| length == maximum }.flat_map do |length, state|
              tree_results(parts[1], characters, cursor + length, state, expanded_flags).map do |tail, inner|
                [length + tail, inner]
              end
            end
          end
          if parts.length == 3 && parts[0].is_a?(SemanticBytecode::Anchor) &&
             parts[0].kind == :anchor_absolute_start &&
             fold_property_alternation_anchor_expansion?(parts[1], parts[2], characters, cursor)
            expanded_flags = flags.merge(property_alternation_anchor: true)
            prefix = tree_results(parts[0], characters, cursor, captures, expanded_flags)
            return prefix.flat_map do |prefix_length, state|
              first_results = tree_results(parts[1], characters, cursor + prefix_length, state, expanded_flags)
              maximum = first_results.map(&:first).max
              first_results.select { |length, _inner| length == maximum }.flat_map do |length, inner|
                tree_results(parts[2], characters, cursor + prefix_length + length, inner, expanded_flags).map do |tail, final_state|
                  [prefix_length + length + tail, final_state]
                end
              end
            end
          end

          states = [[0, captures]]
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
              if run.length > 1 &&
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
            # rubocop:disable Metrics/BlockLength
            states = previous_states.flat_map do |consumed, state_captures|
              fold_marker = state_captures[:__captured_expanded_fold] ||
                            state_captures[:__expanded_fold] ||
                            state_captures[:__quantifier_expanded_fold]
              next [] if captured_fold_literal_tail_rejected?(part, state_captures)

              if part.is_a?(SemanticBytecode::CharacterClass) &&
                 state_captures[:__group_expanded_literal_boundary]&.fetch(:kind, nil) == :simple_fold_source
                state_captures = clear_fold_boundary_markers(state_captures)
              end

              keep_capture_fold = state_captures[:__fold_alternation_operand] ||
                                  fold_alternation_operand_node?(part) ||
                                  (part.is_a?(SemanticBytecode::Assertion) && part.kind == :positive)
              unless keep_capture_fold || !fold_marker
                state_captures = state_captures.dup
                state_captures.delete(:__captured_expanded_fold)
                state_captures.delete(:__captured_expanded_fold_source)
                state_captures.delete(:__expanded_fold)
                state_captures.delete(:__quantifier_expanded_fold)
                state_captures.delete(:__quantifier_expanded_optional)
                state_captures.delete(:__group_expanded_literal_source)
                state_captures.delete(:__group_expanded_literal_fold)
                state_captures.delete(:__group_expanded_literal_boundary)
                state_captures.delete(:__group_expanded_literal_prefix)
              end
              # A match-reset before an absence is a zero-width VM marker.
              # Do not expose its synthetic start to the absence probe; the
              # probe must still scan the remaining input. Restore the marker
              # after the absence consumes its complement.
              reset_start = (state_captures[:__match_start] if contains_absence_node?(part) && state_captures[:__match_reset])
              probe_captures = if reset_start
                                 state_captures.dup.tap { |state| state.delete(:__match_start) }
                               else
                                 state_captures
                               end
              part_flags = if negated_class_casefold_barrier?(part, parts[index], flags)
                             flags.merge(negated_class_casefold_barrier: true)
                           else
                             flags
                           end
              part_cursor = cursor + consumed
              # A shifted absence carries its internal start and end in VM
              # state. Execute the next operand at that start, not at the
              # sequence origin. The reported match still uses the end.
              if state_captures[:__match_start].is_a?(Integer) &&
                 state_captures[:__match_end].is_a?(Integer) &&
                 state_captures[:__match_start] > part_cursor
                part_cursor = state_captures[:__match_start]
              end
              part_flags = part_flags.merge(posix_anchor_expansion: true) if posix_expanded_optional_anchor?(part, parts[index], characters, cursor + consumed)
              if fold_property_alternation_anchor_expansion?(part, parts[index],
                                                             characters, cursor + consumed)
                part_flags = part_flags.merge(property_alternation_anchor: true)
              end
              part_results = if state_captures[:__lookbehind_overlap_source] &&
                                state_captures[:__lookbehind_prior_overlap_source] &&
                                part.is_a?(SemanticBytecode::Quantifier) &&
                                part.expression.is_a?(SemanticBytecode::Literal) &&
                                part.expression.value.length == 1 &&
                                prior_overlap_exact?(state_captures, part.expression.value)
                               next_state = state_captures.dup
                               next_state.delete(:__lookbehind_overlap)
                               next_state.delete(:__lookbehind_overlap_source)
                               next_state.delete(:__lookbehind_overlap_values)
                               next_state.delete(:__lookbehind_overlap_alternation)
                               next_state.delete(:__lookbehind_overlap_expanded)
                               next_state.delete(:__lookbehind_direct_tail_reject)
                               next_state.delete(:__lookbehind_prior_overlap_source)
                               next_state.delete(:__lookbehind_prior_overlap_values)
                               tree_results(part, characters, cursor + consumed, next_state, part_flags)
                             elsif state_captures[:__lookbehind_overlap_source] &&
                                   part.is_a?(SemanticBytecode::Quantifier) &&
                                   part.expression.is_a?(SemanticBytecode::Literal)
                               lookbehind_overlap_quantifier_results(
                                 part, characters, cursor + consumed, state_captures, part_flags
                               )
                             elsif state_captures[:__lookbehind_overlap_source] &&
                                   part.is_a?(SemanticBytecode::CharacterClass) &&
                                   state_captures[:__lookbehind_overlap].to_i == 1 &&
                                   class_match?(part, state_captures[:__lookbehind_overlap_source],
                                                part_flags.merge(ignorecase: true))
                               [[0, clear_lookbehind_overlap_state(state_captures)]]
                             elsif state_captures[:__lookbehind_prior_overlap_source] &&
                                   part.is_a?(SemanticBytecode::Literal) &&
                                   part.value.length == 1 &&
                                   prior_overlap_exact?(state_captures, part.value) &&
                                   casefold_equal?(part.value.each_char.first.to_s,
                                                   state_captures[:__lookbehind_overlap_source])
                               next_state = state_captures.dup
                               next_state.delete(:__lookbehind_overlap)
                               next_state.delete(:__lookbehind_overlap_source)
                               next_state.delete(:__lookbehind_overlap_values)
                               next_state.delete(:__lookbehind_overlap_alternation)
                               next_state.delete(:__lookbehind_overlap_expanded)
                               next_state.delete(:__lookbehind_direct_tail_reject)
                               next_state.delete(:__lookbehind_prior_overlap_source)
                               next_state.delete(:__lookbehind_prior_overlap_values)
                               next_state.delete(:__lookbehind_prior_overlap_source)
                               tree_results(part, characters, cursor + consumed, next_state, part_flags)
                             elsif state_captures[:__lookbehind_overlap_source] && part.is_a?(SemanticBytecode::Literal)
                               overlap_source = state_captures[:__lookbehind_overlap_source]
                               overlap_chars = part.value.each_char.to_a
                               overlap_count = state_captures[:__lookbehind_overlap].to_i
                               overlap_prefix = overlap_chars.first(overlap_count).join
                               folded_chars = (part.casefold || part.value).each_char.to_a
                               overlap_values = state_captures[:__lookbehind_overlap_values] || []
                               body_matches_source = overlap_values.any? do |value|
                                 casefold_equal?(value, overlap_source)
                               end
                               body_matches_source ||= lookbehind_overlap_suffix?(
                                 overlap_values, overlap_source, overlap_count
                               )
                               expanded_overlap_allowed = (state_captures[:__lookbehind_overlap_expanded] ||
                                                           state_captures[:__lookbehind_reverse_fold]) &&
                                                          (index < parts.length - 1 ||
                                                           part.value.length > 1 ||
                                                           (part.casefold && part.casefold.length > part.value.length))
                               if overlap_count.positive? &&
                                  (!state_captures[:__lookbehind_direct_tail_reject] ||
                                   (part.casefold && part.casefold.length > part.value.length)) &&
                                  casefold_equal?(overlap_prefix, overlap_source) &&
                                  (body_matches_source || expanded_overlap_allowed)
                                 remainder = overlap_chars.drop(overlap_count).join
                                 next_state = state_captures.dup
                                 next_state.delete(:__lookbehind_overlap)
                                 next_state.delete(:__lookbehind_overlap_source)
                                 next_state.delete(:__lookbehind_overlap_values)
                                 next_state.delete(:__lookbehind_overlap_alternation)
                                 next_state.delete(:__lookbehind_overlap_expanded)
                                 next_state.delete(:__lookbehind_direct_tail_reject)
                                 next_state.delete(:__lookbehind_prior_overlap_source)
                                 next_state.delete(:__lookbehind_prior_overlap_values)
                                 if remainder.empty?
                                   [[0, next_state]]
                                 else
                                   tree_results(SemanticBytecode::Literal.new(remainder, nil, nil, false),
                                                characters, cursor + consumed, next_state, part_flags)
                                 end
                               elsif overlap_count == 1 &&
                                     cursor + consumed < characters.length &&
                                     casefold_equal?(part.value, characters[cursor + consumed])
                                 next_state = state_captures.dup
                                 next_state.delete(:__lookbehind_overlap)
                                 next_state.delete(:__lookbehind_overlap_source)
                                 next_state.delete(:__lookbehind_overlap_values)
                                 next_state.delete(:__lookbehind_overlap_alternation)
                                 next_state.delete(:__lookbehind_overlap_expanded)
                                 next_state.delete(:__lookbehind_direct_tail_reject)
                                 next_state.delete(:__lookbehind_prior_overlap_source)
                                 next_state.delete(:__lookbehind_prior_overlap_values)
                                 [[0, next_state]]
                               elsif overlap_count.positive? &&
                                     (overlap_count <= overlap_source.to_s.downcase(:fold).length ||
                                      (part.casefold && part.casefold.length > part.value.length)) &&
                                     overlap_count < folded_chars.length &&
                                     (part.casefold && part.casefold.length > part.value.length ||
                                      !state_captures[:__lookbehind_overlap_alternation] ||
                                      lookbehind_overlap_suffix?(overlap_values, overlap_source, overlap_count))
                                 remainder = folded_chars.drop(overlap_count).join
                                 next_state = state_captures.dup
                                 next_state.delete(:__lookbehind_overlap)
                                 next_state.delete(:__lookbehind_overlap_source)
                                 next_state.delete(:__lookbehind_overlap_values)
                                 next_state.delete(:__lookbehind_overlap_alternation)
                                 next_state.delete(:__lookbehind_overlap_expanded)
                                 next_state.delete(:__lookbehind_direct_tail_reject)
                                 next_state.delete(:__lookbehind_prior_overlap_source)
                                 next_state.delete(:__lookbehind_prior_overlap_values)
                                 tree_results(SemanticBytecode::Literal.new(remainder, nil, nil, false),
                                              characters, cursor + consumed, next_state, part_flags)
                               else
                                 []
                               end
                             else
                               tree_results(part, characters, part_cursor, probe_captures, part_flags)
                             end
              original_part_results = part_results
              optional_order = fold_casefold_optional_order?(part, parts[index], characters,
                                                             cursor + consumed, flags)
              optional_order = nil if posix_expanded_optional_anchor?(part, parts[index],
                                                                      characters, cursor + consumed)
              case optional_order
              when :zero_only
                part_results = part_results.select { |length, _inner| length.zero? }
              when :single_greedy
                part_results = part_results.select { |length, _inner| length <= 1 }
                part_results = part_results.sort_by { |length, _inner| length.zero? ? 1 : 0 }
              when :greedy
                part_results = part_results.sort_by { |length, _inner| length.zero? ? 1 : 0 }
              end
              if reverse_fold_optional_barrier?(part, parts[index + 1], parts[index + 2],
                                                characters, cursor + consumed, flags)
                return []
              end

              previous_part = part_index.positive? ? parts[part_index - 1] : nil
              if previous_part.is_a?(SemanticBytecode::Assertion) &&
                 previous_part.kind == :positive &&
                 state_captures[:__expanded_literal_source] &&
                 part.is_a?(SemanticBytecode::Literal) &&
                 simple_fold_source_match?(part, characters[cursor + consumed])
                part_results = []
              end
              if previous_part.is_a?(SemanticBytecode::Assertion) &&
                 previous_part.kind == :positive &&
                 (lookahead_fold = state_captures[:__fold_lookahead_expanded]) &&
                 (boundary = boundary_operand(part))
                candidate = if boundary.is_a?(SemanticBytecode::Literal)
                              boundary
                            elsif boundary.is_a?(SemanticBytecode::Quantifier) &&
                                  boundary.expression.is_a?(SemanticBytecode::Literal)
                              boundary.expression
                            end
                candidate_fold = candidate&.value&.downcase(:fold)
                input_fold = characters[cursor + consumed]&.downcase(:fold)
                if candidate && ((lookahead_fold.is_a?(String) && candidate_fold == lookahead_fold && input_fold == lookahead_fold) ||
                                 (lookahead_fold == true && candidate_fold == input_fold && input_fold.length > 1))
                  part_results = []
                end
              end
              part_results = [] if part.is_a?(SemanticBytecode::Anchor) && state_captures[:__lookbehind_direct_tail_reject]
              if state_captures[:__expanded_literal_source] &&
                 state_captures[:__expanded_literal_boundary]&.fetch(:kind, nil) == :simple_fold_source &&
                 previous_part.is_a?(SemanticBytecode::OptionGroup) &&
                 part.is_a?(SemanticBytecode::Literal) &&
                 !state_captures[:__optional_fold_zero] &&
                 !state_captures[:__lookbehind_simple_fold_source] &&
                 !state_captures[:__fold_alternation_context] &&
                 !state_captures[:__match_alternative]
                part_results = []
              end
              part_results = [] if state_captures[:__simple_fold_alternation_source] &&
                                   ((part.is_a?(SemanticBytecode::Literal) &&
                                     !simple_fold_source_match?(part, characters[cursor + consumed])) ||
                                    part.is_a?(SemanticBytecode::Anchor) ||
                                    part.is_a?(SemanticBytecode::Assertion))
              part_results = [] if state_captures[:__expanded_fold_alternation_source] &&
                                   ((part.is_a?(SemanticBytecode::Literal) &&
                                     !simple_fold_source_match?(part, characters[cursor + consumed])) ||
                                    part.is_a?(SemanticBytecode::Anchor) ||
                                    part.is_a?(SemanticBytecode::Assertion))
              if simple_fold_lookahead_boundary?(part, parts[index], characters,
                                                 cursor + consumed, flags)
                part_results = []
              end
              if simple_fold_sequence_boundary?(part, parts[index], characters,
                                                cursor + consumed, flags)
                part_results = []
              end
              boundary_relaxed = state_captures[:__optional_fold_zero] ||
                                 fold_boundary_relaxed?(previous_part, part, consumed) ||
                                 fold_boundary_lookahead_relaxed?(previous_part, part,
                                                                  parts[index], characters,
                                                                  cursor + consumed) ||
                                 alternate_anchor_relaxed?(part, parts[index],
                                                           characters, cursor + consumed,
                                                           flags) ||
                                 optional_expanded_quantifier?(part)
              if !boundary_relaxed &&
                 multi_fold_literal_boundary?(part, parts[index], characters,
                                              cursor + consumed, flags)
                part_results = []
              end
              if !boundary_relaxed &&
                 multi_fold_quantifier_boundary?(part, parts[index], characters,
                                                 cursor + consumed, flags)
                part_results = []
              end
              if alternate_fold_quantifier_anchor_boundary?(part, parts[index],
                                                            characters, cursor + consumed,
                                                            flags)
                part_results = []
              end
              if distinct_expanded_anchor_boundary?(part, parts[index], characters,
                                                    cursor + consumed,
                                                    flags) &&
                 part_results.all? { |length, _inner| length <= 1 }
                part_results = []
              end
              if expanded_fold_prefix_boundary?(part, parts[index], characters,
                                                cursor + consumed, flags)
                part_results = []
              end
              if reverse_fold_quantifier_anchor_reject?(part, parts[index], characters,
                                                        cursor + consumed, flags)
                part_results = []
              elsif reverse_fold_quantifier_anchor_source_width?(part, parts[index], characters,
                                                                 cursor + consumed, flags)
                part_results = part_results.select { |length, _inner| length <= part.minimum }
              end
              if split_reverse_fold_quantifier_anchor_boundary?(part_index.positive? && parts[part_index - 1],
                                                                part, parts[index], characters,
                                                                cursor + consumed, flags)
                part_results = []
              end
              posix_anchor_mode = posix_anchor_source_width?(part, parts[index], characters, cursor + consumed)
              if posix_anchor_mode == :source_only
                limit = part.is_a?(SemanticBytecode::Quantifier) ? part.maximum : 1
                part_results = part_results.select { |length, _inner| length <= limit }
              elsif posix_anchor_mode == :expanded_greedy
                part_results = part_results.sort_by { |length, _inner| -length }
              end
              if reverse_fold_literal_anchor_boundary?(part, parts[index], characters,
                                                       cursor + consumed, flags)
                part_results = []
              end
              if strict_end_anchor?(parts[index]) &&
                 (anchor_operand = boundary_operand(part))
                anchor_operand = anchor_operand.parts.last if anchor_operand.is_a?(SemanticBytecode::Sequence)
                if anchor_operand.is_a?(SemanticBytecode::Literal) &&
                   !anchor_operand.value.match?(/\p{M}/) &&
                   anchor_operand.fold_policy&.fetch(:anchor_source, nil) == :fold_group_variant &&
                   Onibi::UnicodeProperties.reverse_casefold_variants(anchor_operand.value.downcase(:fold)).include?(anchor_operand.value) &&
                   characters[cursor + consumed - 1] == anchor_operand.value
                  part_results = []
                end
                if anchor_operand.is_a?(SemanticBytecode::Literal) &&
                   anchor_operand.fold_policy&.fetch(:alternation_source, nil) == :reject_reverse_variant
                  source = characters[cursor + consumed - 1]
                  if source && !source.match?(/\p{M}/) &&
                     Onibi::UnicodeProperties.reverse_casefold_variants(anchor_operand.value.downcase(:fold)).include?(source)
                    part_results = []
                  end
                end
              end
              if strict_end_anchor?(parts[index]) &&
                 (anchor_operand = boundary_operand(part)).is_a?(SemanticBytecode::Literal)
                source = characters[cursor + consumed - 1]
                if source && !source.match?(/\p{M}/) &&
                   anchor_operand.fold_policy&.fetch(:alternation_source, nil) == :reject_reverse_variant &&
                   Onibi::UnicodeProperties.reverse_casefold_variants(anchor_operand.value.downcase(:fold)).include?(source)
                  part_results = []
                end
              end
              if previous_part.is_a?(SemanticBytecode::Assertion) && previous_part.kind == :positive &&
                 strict_end_anchor?(parts[index]) &&
                 (lookahead_operand = boundary_operand(part))
                lookahead_operand = lookahead_operand.parts.last if lookahead_operand.is_a?(SemanticBytecode::Sequence)
                if lookahead_operand.is_a?(SemanticBytecode::Literal) &&
                   lookahead_operand.fold_policy&.fetch(:alternation_source, nil) == :reject_reverse_variant
                  source = characters[cursor + consumed]
                  if source && !source.match?(/\p{M}/) &&
                     Onibi::UnicodeProperties.reverse_casefold_variants(lookahead_operand.value.downcase(:fold)).include?(source)
                    part_results = []
                  end
                end
              end
              if strict_end_anchor?(parts[index]) &&
                 (alternative = boundary_operand(part)).is_a?(SemanticBytecode::Alternation)
                source = characters[cursor + consumed - 1]
                if source && !source.match?(/\p{M}/) &&
                   alternative.fold_policy&.fetch(:anchor_alternation, nil) == :reject_reverse_variant &&
                   alternative.branches.any? do |branch|
                     operand = boundary_operand(branch)
                     operand.is_a?(SemanticBytecode::Literal) &&
                     Onibi::UnicodeProperties.reverse_casefold_variants(operand.value.downcase(:fold)).include?(source)
                   end
                  part_results = []
                end
                if source && !source.match?(/\p{M}/) && alternative.branches.any? do |branch|
                  operand = boundary_operand(branch)
                  operand.is_a?(SemanticBytecode::Literal) &&
                  operand.fold_policy&.fetch(:alternation_source, nil) == :reject_reverse_variant &&
                  Onibi::UnicodeProperties.reverse_casefold_variants(operand.value.downcase(:fold)).include?(source)
                end
                  part_results = []
                end
              end
              if (alternative = boundary_operand(part)).is_a?(SemanticBytecode::Alternation) &&
                 parts[index].is_a?(SemanticBytecode::Literal)
                source = characters[cursor + consumed]
                if source && !source.match?(/\p{M}/) &&
                   alternative.branches.any? do |branch|
                     operand = boundary_operand(branch)
                     operand.is_a?(SemanticBytecode::Literal) &&
                     operand.fold_policy&.fetch(:alternation_source, nil) == :reject_reverse_variant &&
                     Onibi::UnicodeProperties.reverse_casefold_variants(operand.value.downcase(:fold)).include?(source)
                   end && characters[cursor + consumed + 1] &&
                   casefold_equal?(parts[index].value, characters[cursor + consumed + 1])
                  part_results = []
                end
              end
              if reverse_fold_optional_anchor_boundary?(part, parts[index],
                                                        characters, cursor + consumed, flags)
                part_results = part_results.select { |length, _inner| length.zero? }
              end
              if part.is_a?(SemanticBytecode::OptionGroup) &&
                 part.body.is_a?(SemanticBytecode::Sequence) && part.body.parts.one? &&
                 (optional = part.body.parts.first).is_a?(SemanticBytecode::Quantifier) &&
                 optional.minimum.zero? && optional.maximum == 1 &&
                 optional.expression.is_a?(SemanticBytecode::Literal) &&
                 parts[index].is_a?(SemanticBytecode::Literal)
                source = characters[cursor + consumed]
                variants = Onibi::UnicodeProperties.reverse_casefold_variants(
                  optional.expression.value.downcase(:fold)
                )
                if source && !source.match?(/\p{M}/) && variants.include?(source) &&
                   characters[cursor + consumed + 1] &&
                   casefold_equal?(parts[index].value, characters[cursor + consumed + 1])
                  part_results = part_results.select { |length, _inner| length.zero? }
                end
              end
              if posix_alternation_anchor_source_width?(part, parts[index],
                                                        characters, cursor + consumed)
                part_results = part_results.select { |length, _inner| length <= 1 }
              end
              if fold_property_alternation_anchor_expansion?(part, parts[index],
                                                             characters, cursor + consumed)
                maximum = part_results.map(&:first).max
                part_results = part_results.select { |length, _inner| length == maximum }
              end
              if alternate_fold_alternation_anchor_boundary?(part, parts[index],
                                                             characters, cursor + consumed, flags)
                part_results = []
              end
              if alternate_fold_literal_run_anchor_boundary?(part, parts[index],
                                                             characters, cursor + consumed,
                                                             flags)
                part_results = []
              end
              if backreference_anchor_boundary?(part, parts[index], state_captures,
                                                flags)
                part_results = []
              end
              if positive_lookahead_extra_character_relaxed?(part, parts[index],
                                                             characters, cursor + consumed)
                part_results = original_part_results
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
                if reset_start
                  inner = inner.dup
                  inner[:__match_start] = reset_start
                  inner[:__match_reset] = true
                end
                next_state = if node.parts.length > 1 && inner.key?(:__match_start) && !inner.key?(:__match_prefix)
                               marked = inner.dup
                               marked[:__match_prefix] = consumed
                               marked[:__match_prefix_value] = characters[cursor, consumed].join
                               marked[:__match_prefix_zero_absence] = state_captures[:__zero_absence]
                               marked
                             else
                               inner
                             end
                if part.is_a?(SemanticBytecode::Literal) &&
                   (state_captures[:__simple_fold_alternation_source] ||
                    state_captures[:__expanded_fold_alternation_source]) &&
                   Array((state_captures[:__expanded_literal_boundary] ||
                         state_captures[:__group_expanded_literal_boundary])&.[](:variants)).include?(
                           characters[cursor + consumed]
                         )
                  next_state = next_state.dup
                  next_state.delete(:__simple_fold_alternation_source)
                  next_state.delete(:__expanded_fold_alternation_source)
                  next_state.delete(:__group_expanded_literal_source)
                  next_state.delete(:__group_expanded_literal_fold)
                  next_state.delete(:__group_expanded_literal_boundary)
                  next_state.delete(:__group_expanded_literal_value)
                end
                if part.is_a?(SemanticBytecode::Quantifier) && part.minimum.zero? && length.zero? &&
                   (state_captures[:__simple_fold_alternation_source] ||
                    state_captures[:__expanded_fold_alternation_source]) &&
                   boundary_operand(part.expression).is_a?(SemanticBytecode::Literal) &&
                   (state_captures[:__expanded_fold_alternation_source] ||
                    characters[cursor]&.downcase(:fold) ==
                    boundary_operand(part.expression).value.downcase(:fold))
                  next_state = next_state.dup
                  next_state.delete(:__simple_fold_alternation_source)
                  next_state.delete(:__expanded_fold_alternation_source)
                end
                if optional_order == :zero_only && length.zero?
                  next_state = next_state.dup
                  next_state[:__optional_fold_zero] = true
                end
                [consumed + length, next_state]
              end
            end
            # rubocop:enable Metrics/BlockLength
            next unless states.empty?

            folded = if previous_states.any? { |_consumed, state| state[:__group_expanded_literal_source] }
                       []
                     else
                       previous_states.flat_map do |consumed, state_captures|
                         casefold_sequence_results(parts.drop(part_index), characters,
                                                   cursor + consumed, state_captures, flags).map do |length, inner|
                           [consumed + length, inner]
                         end
                       end
                     end
            return folded unless folded.empty?

            return []
          end
          states
        when SemanticBytecode::Conditional
          # conditional: select one compiled branch from local capture state.
          conditional_results(node, characters, cursor, captures, flags)
        when SemanticBytecode::Alternation
          # alternation: evaluate branches in bytecode order. Each branch
          # receives a copy of local state and returns ordered candidates.
          branch_flags = flags.merge(fold_alternation: !flags[:property_alternation_anchor])
          branch_marker = node.operand_context ? :__fold_alternation_operand : :__fold_alternation_context
          expanding_alternative = node.branches.any? do |candidate|
            capture_body_has_expanding_literal?(candidate) ||
              (branch_fold_literals(candidate).length > 1 &&
               branch_fold_literals(candidate).any? { |literal| !literal.value.ascii_only? }) ||
              boundary_literal_operands(candidate).any? do |literal|
                folded = literal.value.downcase(:fold)
                variants = Onibi::UnicodeProperties.reverse_casefold_variants(folded)
                variants.any? &&
                  (variants - Onibi::UnicodeProperties.reverse_source_boundary_variants(folded)).any? ||
                  literal.fold_prefix_boundary
              end
          end
          fold_prefix_alternative = node.branches.any? do |candidate|
            boundary_literal_operands(candidate).any?(&:fold_prefix_boundary)
          end
          distinct_alternative = node.branches.map { |candidate| alternation_branch_operand_value(candidate) }.compact.uniq.length > 1
          multichar_alternative = node.branches.any? { |candidate| capture_body_has_expanding_literal?(candidate) }
          expanding_alternative ||= node.fold_policy&.fetch(:expanded_branch, false)
          node.branches.each_with_index.flat_map do |branch, branch_index|
            branch_captures = captures.merge(branch_marker => true)
            branch_value = alternation_branch_operand_value(branch)
            if (captures[:__captured_expanded_fold] || captures[:__expanded_fold]) &&
               node.operand_context &&
               branch_value && captures[:__group_expanded_literal_fold] &&
               !captures[:__group_expanded_literal_fold].start_with?(branch_value) &&
               branch_value != captures[:__captured_expanded_fold_source]
              branch_captures[:__captured_fold_incompatible] = true
            end
            tree_results(branch, characters, cursor, branch_captures, branch_flags).map do |length, state|
              marked = state.dup
              marked.delete(branch_marker)
              if branch_marker == :__fold_alternation_operand && state[:__expanded_literal_source] &&
                 (state[:__expanded_literal_boundary]&.fetch(:kind, nil) == :expanded_tail && distinct_alternative ||
                  (expanding_alternative &&
                   (state[:__expanded_literal_fold] == "s" || state[:__expanded_literal_fold] == "k" && multichar_alternative ||
                    (fold_prefix_alternative && distinct_alternative)) &&
                   state[:__expanded_literal_boundary]&.fetch(:kind, nil) == :simple_fold_source))
                marked[:__fold_alternation_context] = true
              end
              if branch_marker == :__fold_alternation_operand && state[:__expanded_literal_source] &&
                 !expanding_alternative &&
                 state[:__expanded_literal_boundary]&.fetch(:kind, nil) == :simple_fold_source
                marked[:__simple_fold_alternation_source] = true
              end
              branch_operand = boundary_operand(branch)
              if branch_marker == :__fold_alternation_operand &&
                 branch_operand.is_a?(SemanticBytecode::Literal) &&
                 branch_operand.fold_policy&.fetch(:alternation_source, nil) == :reject_non_mark_variant &&
                 characters[cursor] != branch_operand.value &&
                 characters[cursor] && !characters[cursor].match?(/\p{M}/) &&
                 characters[cursor].downcase(:fold) == branch_operand.value.downcase(:fold)
                marked[:__expanded_fold_alternation_source] = true
              end
              if branch_marker == :__fold_alternation_operand && state[:__expanded_literal_source] &&
                 !distinct_alternative &&
                 state[:__expanded_literal_boundary]&.fetch(:kind, nil) == :expanded_tail
                marked[:__expanded_fold_alternation_source] = true
              end
              marked[:__match_alternative] = true
              marked[:__match_alternative_index] = branch_index
              [length, marked]
            end
          end
        when SemanticBytecode::Group
          # group: evaluate the body in a nested capture scope, then publish
          # the group's span together with the body result state.
          with_scope_frame(:group, characters, cursor) do
            group_results = tree_results(node.body, characters, cursor, captures, flags)
            if flags[:property_alternation_anchor]
              maximum = group_results.map(&:first).max
              group_results = group_results.select { |length, _inner| length == maximum }
            end
            group_results.map do |length, inner|
              next_captures = inner.dup
              if flags[:ignorecase] && node.body.is_a?(SemanticBytecode::Alternation) &&
                 node.body.fold_policy&.fetch(:expanded_branch, false) &&
                 next_captures[:__simple_fold_alternation_source]
                next_captures[:__fold_alternation_context] = true
              end
              if deferred_group_fold
                next_captures[:__group_expanded_literal_source] = true
                next_captures[:__group_expanded_literal_fold] = deferred_group_fold.first
                next_captures[:__group_expanded_literal_prefix] = deferred_group_fold[1]
                next_captures[:__group_expanded_literal_boundary] = deferred_group_fold[2]
              end
              expanded_source = next_captures.delete(:__expanded_literal_source)
              expanded_boundary = next_captures.delete(:__expanded_literal_boundary)
              if expanded_source
                next_captures[:__group_expanded_literal_source] = true
                next_captures[:__group_expanded_literal_fold] ||= characters[cursor]&.downcase(:fold)
                next_captures[:__group_expanded_literal_boundary] ||= expanded_boundary
                next_captures[:__group_expanded_literal_value] ||= characters[cursor]
              end
              if node.capture && next_captures[:__group_expanded_literal_source] &&
                 next_captures[:__group_expanded_literal_boundary]&.fetch(:kind, nil) == :expanded_tail
                next_captures[:__captured_expanded_fold] = true
                next_captures[:__captured_expanded_fold_source] = characters[cursor]
              end
              if !node.capture && flags[:ignorecase] && capture_body_has_expanding_literal?(node.body) &&
                 characters[cursor]&.downcase(:fold)&.length.to_i > characters[cursor]&.length.to_i
                next_captures[:__group_expanded_literal_source] = true
                next_captures[:__group_expanded_literal_fold] = characters[cursor].downcase(:fold)
                next_captures[:__group_expanded_literal_boundary] = fold_boundary_for_node(node.body)
              end
              if node.capture
                next_captures[node.number] = [cursor, cursor + length]
                next_captures[node.name] = [cursor, cursor + length] if node.name
                if capture_body_has_class?(node.body)
                  next_captures[:__class_capture_numbers] = Array(next_captures[:__class_capture_numbers])
                  next_captures[:__class_capture_numbers] << node.number
                end
              end
              [length, next_captures]
            end
          end
        when SemanticBytecode::Quantifier
          # quantifier: delegate repeat-frame creation and ordered candidates.
          with_scope_frame(:quantifier, characters, cursor) do
            quantifier_results(node, characters, cursor, captures, flags)
          end
        when SemanticBytecode::OptionGroup
          # option_group: replace only the flags declared by the operand;
          # cursor and capture state are returned by the body.
          with_scope_frame(:option_group, characters, cursor) do
            scoped_flags = flags.dup
            scoped_flags[:ignorecase] = node.ignorecase unless node.ignorecase.nil?
            scoped_flags[:multiline] = node.multiline unless node.multiline.nil?
            tree_results(node.body, characters, cursor, captures, scoped_flags)
          end
        when SemanticBytecode::AtomicGroup
          # atomic_group: keep the first body candidate and discard later
          # backtracking candidates.
          with_scope_frame(:atomic_group, characters, cursor) do
            tree_results(node.body, characters, cursor, captures, flags).first(1)
          end
        when SemanticBytecode::Assertion
          # assertion: evaluate the body without consuming input.
          with_scope_frame(:assertion, characters, cursor) do
            assertion_results(node, characters, cursor, captures, flags)
          end
        when SemanticBytecode::SubexpressionCall
          # subexpression_call: call the compiled operand with the same cursor
          # and local state, subject to the recursion limit.
          body = @subexpressions[node.identifier]
          return [] unless body
          return [] if (@subexpression_depth ||= 0) > 32

          @subexpression_depth += 1
          results = tree_results(body, characters, cursor, captures, flags)
          @subexpression_depth -= 1
          results
        when SemanticBytecode::Absence
          # absence: evaluate the complement probe and preserve its frame
          # checkpoint in each result's local state.
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

          # Onigmo keeps a reverse-fold lookbehind overlap at the end of the
          # string as a zero-width match for class and any-character opcodes.
          # Preserve that VM state until the following opcode consumes it.
          if captures[:__lookbehind_reverse_fold] && cursor >= characters.length &&
             (node.is_a?(SemanticBytecode::CharacterClass) || node.is_a?(SemanticBytecode::Property) ||
              node.is_a?(SemanticBytecode::Any))
            next_captures = captures.dup
            next_captures.delete(:__lookbehind_overlap)
            next_captures.delete(:__lookbehind_reverse_fold)
            next_captures.delete(:__lookbehind_overlap_source)
            next_captures.delete(:__lookbehind_overlap_values)
            next_captures.delete(:__lookbehind_overlap_alternation)
            next_captures.delete(:__lookbehind_overlap_expanded)
            next_captures.delete(:__lookbehind_direct_tail_reject)
            next_captures.delete(:__lookbehind_prior_overlap_source)
            next_captures.delete(:__lookbehind_prior_overlap_values)
            return [[0, next_captures]]
          end

          length = transition_length([operation_for(node), node], characters, cursor, flags, captures)
          if captures[:__lookbehind_overlap] || captures[:__lookbehind_reverse_fold]
            return [] unless length

            next_captures = captures.dup
            next_captures.delete(:__lookbehind_overlap)
            next_captures.delete(:__lookbehind_reverse_fold)
            next_captures.delete(:__lookbehind_overlap_source)
            next_captures.delete(:__lookbehind_overlap_values)
            next_captures.delete(:__lookbehind_overlap_alternation)
            next_captures.delete(:__lookbehind_overlap_expanded)
            next_captures.delete(:__lookbehind_direct_tail_reject)
            next_captures.delete(:__lookbehind_prior_overlap_source)
            next_captures.delete(:__lookbehind_prior_overlap_values)
            captures = next_captures
          else
            return [] unless length
          end

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
              if !flags[:skip_fold_marker] && flags[:ignorecase] && class_length == 1 &&
                 (fold = class_expanded_fold(node, characters[cursor]))
                marked = captures.dup
                marked[:__expanded_literal_source] = true
                marked[:__expanded_literal_fold] = fold
                marked[:__expanded_literal_boundary] = node.fold_boundaries[characters[cursor]]
                marked[:__expanded_literal_from_class] = true
                marked[:__expanded_literal_value] = characters[cursor]
                marked[:__expanded_fold] = true if marked[:__expanded_literal_boundary]&.fetch(:kind, nil) == :expanded_tail
                next [class_length, marked]
              end
              [class_length, captures]
            end
          end

          if (marked = literal_fold_marker(node, characters, cursor, captures, flags, length))
            return [[length, marked]]
          end

          if node.is_a?(SemanticBytecode::Anchor) && strict_end_anchor?(node) &&
             (captures[:__group_expanded_literal_source] || captures[:__expanded_literal_source])
            captures = captures.dup
            captures[:__expanded_fold_anchor] = true
            if captures[:__expanded_literal_source]
              captures[:__group_expanded_literal_source] = true
              captures[:__group_expanded_literal_fold] ||= captures[:__expanded_literal_fold]
              captures[:__group_expanded_literal_boundary] ||= captures[:__expanded_literal_boundary]
            end
          end
          [[length, captures]]
        end
      end

      # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
    end
  end
end

# rubocop:enable Metrics/ModuleLength
