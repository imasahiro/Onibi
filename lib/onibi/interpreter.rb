# frozen_string_literal: true

module Onibi
  module Interpreter
    # SemanticBytecode is the compiler-owned operand model.
    SemanticBytecode = Onibi::IRGen::YARVIR::SemanticBytecode

    # All mutable invocation and scope state has one owner.  ExecutionFrame
    # names the nested scope shape only; it is not a second runtime state.
    ExecutionState = Onibi::ExecutionState
    ExecutionFrame = ExecutionState::Frame

    # Formal VM contract:
    #
    #   VM state = <cursor, operand_stack, local_state, frame_stack>
    #   operand_stack = [[length, next_local_state], ...]
    #   local_state = captures plus compiler-defined internal keys
    #   frame_stack = nested ExecutionFrame values
    #
    # `cursor` is a character index in `InputView#characters`. An instruction
    # reads one operand and one VM state, then pushes zero or more ordered
    # results. A result does not mutate its input local state. The caller
    # merges the result state and advances the cursor by `length`.
    #
    # The `input`, `stack_transition`, `local_transition`, `cursor_transition`,
    # `control`, and `failure` fields below are the formal transition for each
    # opcode. The shorter `stack` and `local` fields remain as labels for
    # existing callers. `:read` means that a value is inspected but not
    # changed. `:preserve` means that the value is returned unchanged.
    #
    # DFA: start(state), match(label), jump(state), accept(state).
    # TNFA: nfa_start(states), nfa_match([from, to, [opcode, operand]]),
    # nfa_accept(states). Match consumes input and advances the cursor.
    # Jump and start change control state only. Accept returns the match.
    BYTECODE_SPEC = {
      dfa: {
        start: {
          signature: "start(state_id)", operand: :state_id,
          input: { operand: :read, characters: :unused, flags: :unused }.freeze,
          stack_transition: :preserve, local_transition: :preserve,
          cursor_transition: :preserve, control: :select_state, failure: :reject
        },
        match: {
          signature: "match(transition_label)", operand: :transition_label,
          input: { operand: :read, characters: :read, flags: :read }.freeze,
          stack_transition: :push_results, local_transition: :merge_result,
          cursor_transition: :advance_by_result, control: :follow_transition,
          failure: :try_next_transition
        },
        jump: {
          signature: "jump(state_id)", operand: :state_id,
          input: { operand: :read, characters: :unused, flags: :unused }.freeze,
          stack_transition: :preserve, local_transition: :preserve,
          cursor_transition: :preserve, control: :select_state, failure: :reject
        },
        accept: {
          signature: "accept(state_id)", operand: :state_id,
          input: { operand: :read, characters: :unused, flags: :unused }.freeze,
          stack_transition: :halt, local_transition: :return_result,
          cursor_transition: :preserve, control: :return_match, failure: :reject
        }
      },
      tnfa: {
        nfa_start: {
          signature: "nfa_start(state_ids)", operand: :state_ids,
          input: { operand: :read, characters: :unused, flags: :unused }.freeze,
          stack_transition: :preserve, local_transition: :set_active_states,
          cursor_transition: :preserve, control: :follow_epsilon_closure,
          failure: :reject
        },
        nfa_match: {
          signature: "nfa_match(edge)", operand: :edge,
          input: { operand: :read, characters: :read, flags: :read }.freeze,
          stack_transition: :push_results, local_transition: :merge_result,
          cursor_transition: :advance_by_result, control: :follow_edge,
          failure: :try_next_edge
        },
        nfa_accept: {
          signature: "nfa_accept(state_ids)", operand: :state_ids,
          input: { operand: :read, characters: :unused, flags: :unused }.freeze,
          stack_transition: :halt, local_transition: :return_result,
          cursor_transition: :preserve, control: :return_match, failure: :reject
        }
      },
      semantic: {
        match_literal: {
          signature: "match_literal(literal)", operand: :literal,
          input: { operand: :read, characters: :read, flags: :read }.freeze,
          stack_transition: :push_results, local_transition: :merge_result,
          cursor_transition: :advance_by_result, control: :continue, failure: :reject
        },
        match_class: {
          signature: "match_class(character_class)", operand: :character_class,
          input: { operand: :read, characters: :read, flags: :read }.freeze,
          stack_transition: :push_results, local_transition: :merge_result,
          cursor_transition: :advance_by_result, control: :continue, failure: :reject
        },
        match_escape: {
          signature: "match_escape(escape)", operand: :escape,
          input: { operand: :read, characters: :read, flags: :read }.freeze,
          stack_transition: :push_results, local_transition: :merge_result,
          cursor_transition: :advance_by_result, control: :continue, failure: :reject
        },
        match_property: {
          signature: "match_property(property)", operand: :property,
          input: { operand: :read, characters: :read, flags: :read }.freeze,
          stack_transition: :push_results, local_transition: :merge_result,
          cursor_transition: :advance_by_result, control: :continue, failure: :reject
        },
        match_any: {
          signature: "match_any(dot)", operand: :dot,
          input: { operand: :read, characters: :read, flags: :read }.freeze,
          stack_transition: :push_results, local_transition: :merge_result,
          cursor_transition: :advance_by_result, control: :continue, failure: :reject
        },
        match_assertion: {
          signature: "match_assertion(assertion)", operand: :assertion,
          input: { operand: :read, characters: :read, flags: :read }.freeze,
          stack_transition: :push_results, local_transition: :zero_width_result,
          cursor_transition: :preserve, control: :continue, failure: :reject
        },
        test_anchor: {
          signature: "test_anchor(anchor)", operand: :anchor,
          input: { operand: :read, characters: :read, flags: :read }.freeze,
          stack_transition: :push_results, local_transition: :zero_width_result,
          cursor_transition: :preserve, control: :continue, failure: :reject
        },
        match_absence: {
          signature: "match_absence(absence)", operand: :absence,
          input: { operand: :read, characters: :read, flags: :read }.freeze,
          stack_transition: :push_results, local_transition: :restore_frame_state,
          cursor_transition: :advance_by_result, control: :probe_with_bounded_end,
          failure: :reject,
          language: :complement_of_wrapped_body,
          wrapped_language: ".* body .*",
          preserves: :ordered_body_candidates,
          capture_checkpoint: :repeat_frame_state,
          transition: :probe_with_bounded_end
        },
        match_group: {
          signature: "match_group(group)", operand: :group,
          input: { operand: :read, characters: :read, flags: :read }.freeze,
          stack_transition: :push_results, local_transition: :enter_capture_scope,
          cursor_transition: :advance_by_result, control: :continue, failure: :reject
        },
        match_quantifier: {
          signature: "match_quantifier(quantifier)", operand: :quantifier,
          input: { operand: :read, characters: :read, flags: :read }.freeze,
          stack_transition: :push_results, local_transition: :repeat_and_merge,
          cursor_transition: :advance_by_result, control: :continue, failure: :reject
        },
        match_atomic_group: {
          signature: "match_atomic_group(atomic_group)", operand: :atomic_group,
          input: { operand: :read, characters: :read, flags: :read }.freeze,
          stack_transition: :push_first_result, local_transition: :commit_scope,
          cursor_transition: :advance_by_result, control: :continue, failure: :reject
        },
        match_backreference: {
          signature: "match_backreference(capture_number)", operand: :capture_number,
          input: { operand: :read, characters: :read, flags: :read }.freeze,
          stack_transition: :push_results, local_transition: :merge_result,
          cursor_transition: :advance_by_result, control: :continue, failure: :reject
        },
        match_conditional: {
          signature: "match_conditional(conditional)", operand: :conditional,
          input: { operand: :read, characters: :read, flags: :read }.freeze,
          stack_transition: :push_results, local_transition: :branch,
          cursor_transition: :advance_by_result, control: :continue, failure: :reject
        },
        match_subexpression_call: {
          signature: "match_subexpression_call(capture_number)", operand: :capture_number,
          input: { operand: :read, characters: :read, flags: :read }.freeze,
          stack_transition: :push_results, local_transition: :call_and_merge,
          cursor_transition: :advance_by_result, control: :continue, failure: :reject
        },
        semantic_match: {
          signature: "semantic_match(program)", operand: :semantic_program,
          input: { operand: :read, characters: :read, flags: :read }.freeze,
          stack_transition: :push_results, local_transition: :merge_result,
          cursor_transition: :advance_by_result, control: :continue, failure: :reject
        },
        match_option_group: {
          signature: "match_option_group(option_group)", operand: :option_group,
          input: { operand: :read, characters: :read, flags: :read }.freeze,
          stack_transition: :push_results, local_transition: :scope_flags,
          cursor_transition: :advance_by_result, control: :continue, failure: :reject
        }
      }
    }.each_value do |family|
      family.each_value do |spec|
        spec[:stack] = {
          preserve: :unchanged,
          push_results: :push_result,
          push_first_result: :push_result,
          halt: :halt
        }.fetch(spec[:stack_transition])
        spec[:local] = {
          preserve: :state_selected,
          merge_result: :consume_and_merge,
          restore_frame_state: :execution_frame,
          zero_width_result: :zero_width,
          enter_capture_scope: :capture_scope,
          repeat_and_merge: :repeat_and_merge,
          commit_scope: :atomic_scope,
          branch: :branch,
          call_and_merge: :call,
          scope_flags: :scoped_flags,
          set_active_states: :active_states,
          return_result: :return_match
        }.fetch(spec[:local_transition])
        spec[:input] = spec[:input].freeze
        spec.freeze
      end
      family.freeze
    end.freeze

    UNICODE_ENCODINGS = [Encoding::UTF_8, Encoding::UTF_16LE, Encoding::UTF_16BE,
                         Encoding::UTF_32LE, Encoding::UTF_32BE].freeze

    # FoldPolicy is the VM's single Unicode fold classifier.  The compiler
    # puts fold metadata on each operand.  The policy compares one operand
    # with one input character and returns a stable class:
    #
    #   exact          source and operand are equal
    #   simple_source  a one-character reverse fold with a source boundary
    #   reverse_source a reverse fold that is not a source boundary
    #   equivalent     an ordinary case-insensitive match
    #   no_match       the input is outside the operand fold set
    #
    # Boundary code uses this result instead of rebuilding Unicode tables in
    # each assertion, quantifier, and alternation path.
    class FoldPolicy
      def initialize
        @reverse_variants = {}
        @source_variants = {}
      end

      def classify(node, source)
        operand = unwrap(node)
        return :no_match unless source && (operand.is_a?(SemanticBytecode::Literal) ||
                                           operand.is_a?(SemanticBytecode::CharacterClass))

        folded = fold_for(operand, source)
        return :no_match unless folded

        source_variants = source_variants_for(folded)
        return :simple_source if source_variants.include?(source)
        return :reverse_source if reverse_variants_for(folded).include?(source)
        return :exact if operand.is_a?(SemanticBytecode::Literal) && operand.value == source
        return :equivalent if source.downcase(:fold) == folded

        :no_match
      end

      def boundary(node, source)
        operand = unwrap(node)
        return operand.fold_boundary if operand.is_a?(SemanticBytecode::Literal) && operand.fold_boundary
        return operand.fold_boundaries&.[](source) if operand.is_a?(SemanticBytecode::CharacterClass)

        folded = fold_for(operand, source)
        variants = folded && source_variants_for(folded)
        return unless variants&.include?(source)

        { kind: :simple_fold_source, variants: variants.freeze }.freeze
      end

      private

      def unwrap(node)
        loop do
          node = node.body if node.is_a?(SemanticBytecode::Group) ||
                              node.is_a?(SemanticBytecode::OptionGroup) ||
                              node.is_a?(SemanticBytecode::AtomicGroup)
          node = node.parts.first if node.is_a?(SemanticBytecode::Sequence) && node.parts.one?
          return node unless node.is_a?(SemanticBytecode::Group) ||
                             node.is_a?(SemanticBytecode::OptionGroup) ||
                             node.is_a?(SemanticBytecode::AtomicGroup) ||
                             (node.is_a?(SemanticBytecode::Sequence) && node.parts.one?)
        end
      end

      def fold_for(operand, source)
        return operand.casefold || operand.value.downcase(:fold) if operand.is_a?(SemanticBytecode::Literal)

        source.downcase(:fold) if operand.is_a?(SemanticBytecode::CharacterClass)
      end

      def source_variants_for(folded)
        @source_variants[folded] ||= Onibi::UnicodeProperties.reverse_source_boundary_variants(folded)
      end

      def reverse_variants_for(folded)
        @reverse_variants[folded] ||= Onibi::UnicodeProperties.reverse_casefold_variants(folded)
      end
    end

    class Executor
      class << self
        def new(program, input_view: nil)
          return super unless self == Executor

          flat = program.instructions.any? { |instruction| instruction.opcode == :semantic_flat } &&
                 !program.instructions.any? { |instruction| instruction.opcode == :semantic_match }
          (flat ? FlatExecutor : CompatibilityExecutor).new(program, input_view: input_view)
        end
      end

      def initialize(program, input_view: nil)
        @program = program
        # Tagged automata are the execution source when the compiler emits
        # tagged VM code. Plain programs keep the compact DFA path.
        @automaton = program.tagged_automaton || program.automaton
        @tagged_vm = !program.tagged_automaton.nil?
        # Semantic matching is an instruction, not a side channel in flags.
        # Programs produced by the current generator carry this operand.
        @flat_program = program.instructions.find { |instruction| instruction.opcode == :semantic_flat }&.operand
        semantic_program = program.instructions.find { |instruction| instruction.opcode == :semantic_match }&.operand
        @semantic_program = semantic_program unless @flat_program
        @semantic_commands = if @flat_program
                               []
                             else
                               program.instructions.find { |instruction| instruction.opcode == :semantic_vm }&.operand || []
                             end
        # A flat program owns its complete control flow.  Do not materialize
        # or retain the semantic tree on this execution path.
        @semantic_entry = semantic_program&.entry_node unless @flat_program
        @automaton_mode = case program.instructions.first&.opcode
                          when :start then :dfa
                          when :nfa_start then :nfa
                          end
        # Flat bytecode contains subexpression bodies as PC targets. Do not
        # retain the source tree table on that path.
        @subexpressions = @flat_program ? {} : (program.flags[:subexpressions] || {})
        @retry_shifted_absence = shifted_absence_suffix?(@semantic_entry)
        @input_view = input_view
        @external_input_view = !input_view.nil?
        @fold_policy = FoldPolicy.new
        @state = ExecutionState.new
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
        input_view = if @external_input_view
                       @input_view
                     else
                       Onibi::InputView.new(input, byte_mode: byte_input)
                     end
        characters = input_view.characters
        characters = normalize_runtime_characters(characters, input_encoding)
        @input_view = input_view
        @characters = characters
        first = [start_position, 0].max
        @state.reset!(cursor: first, search_origin: first)
        # MRI builds encoding-specific character-class tables during compile.
        # Reuse one decision for repeated code points in this execution.
        @property_match_cache = {}
        # Character classes use the input encoding when an ASCII pattern can
        # match several encodings. MRI applies POSIX rules to this encoding.
        runtime_flags = @program.flags.merge(
          encoding: input_encoding,
          full_casefold: @program.flags[:full_casefold] ||
                         (input_encoding == Encoding::UTF_8 && !input_ascii_only)
        )
        first.upto(characters.length) do |start|
          @state.cursor = start
          result = if @flat_program || @semantic_entry
                     raw_results = if @flat_program
                                     execute_flat_semantic_vm(start, characters, {}, runtime_flags)
                                   else
                                     execute_compatibility_vm(start, characters, {}, runtime_flags)
                                   end
                     raw_results.first&.then do |length, captures|
                       next if captures.delete(:__defer_expanded_match)
                       next if expanded_fold_tail_rejected?(captures, characters, start + length)

                       match_start = captures.delete(:__match_start) || start
                       match_end = captures.delete(:__match_end)
                       hidden_captures = captures.delete(:__absence_captures)
                       captures.merge!(hidden_captures) if hidden_captures
                       match_prefix = captures.key?(:__match_prefix)
                       match_reset = captures.delete(:__match_reset)
                       captures.delete(:__match_probe)
                       captures.delete(:__match_prefix)
                       captures.delete(:__match_prefix_value)
                       captures.delete(:__class_capture_numbers)
                       captures.delete(:__reverse_literal_capture_numbers)
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
                                  [start + length, match_end].compact.max
                                else
                                  match_start + length
                                end
                       [match_start, finish, captures]
                     end
                   elsif @automaton_mode
                     initial_state = @automaton_mode == :dfa ? @automaton.start_state.id : :start
                     walk_bytecode(initial_state, characters, start, {}, start, runtime_flags)
                   end
          # A shifted zero-width result is valid when `\\K` reset the match
          # start after an absence probe. Retry only consuming shifted matches.
          next if result && @retry_shifted_absence && result.first > start && result.first != result[1]
          return result if result
        end
        nil
      end

      def normalize_runtime_characters(characters, encoding)
        return characters unless UNICODE_ENCODINGS.include?(encoding) && encoding != Encoding::UTF_8

        characters.map { |character| character.encode(Encoding::UTF_8) }.freeze
      rescue EncodingError
        characters
      end

      # Execute the compatibility semantic stream through the tree evaluator.
      # Flat programs never enter this method.
      def execute_compatibility_vm(cursor, characters, captures, flags)
        command = @semantic_commands[@semantic_program.entry]
        return tree_results(@semantic_entry, characters, cursor, captures, flags) unless command

        case command.opcode
        when :consume, :consume_class, :consume_property, :consume_escape, :consume_any,
             :assert_anchor, :capture, :scope_flags, :atomic, :repeat, :assert,
             :backreference, :conditional, :call, :absence
          node = @semantic_program.entry_node
          opcode = semantic_opcode(node)
          return tree_results(node, characters, cursor, captures, flags) if opcode == :semantic

          transition_results([opcode, node], characters, cursor, captures, flags)
        else
          tree_results(@semantic_entry, characters, cursor, captures, flags)
        end
      end

      # Execute PC-based semantic commands. The stack stores continuations for
      # ordered choice. Capture boundaries use the same capture hash as the
      # compatibility path, so match-data construction stays unchanged.
      def execute_flat_semantic_vm(cursor, characters, captures, flags)
        @state.semantic_stack.clear
        @state.push_semantic_frame(ExecutionState::SemanticFrame.new(
                                     pc: @flat_program.entry, cursor: cursor, captures: captures.dup, flags: flags
                                   ))
        results = []
        until @state.semantic_stack.empty?
          frame = @state.pop_semantic_frame
          pc = frame.pc
          position = frame.cursor
          state = frame.captures
          frame_flags = frame.flags
          @state.steps += 1
          next if @state.steps > 2_000_000

          if pc >= @flat_program.instructions.length
            results << [position - cursor, state]
            next
          end

          instruction = @flat_program.instruction_at(pc)
          next unless instruction

          case instruction.opcode
          when :accept
            results << [position - cursor, state]
          when :call
            target = @flat_program.call_target(instruction.operand)
            next unless target

            @state.push_call(pc + 1)
            @state.push_semantic_frame(ExecutionState::SemanticFrame.new(
                                         pc: target, cursor: position, captures: state,
                                         flags: frame_flags
                                       ))
          when :return
            call_frame = @state.calls.last
            return_pc = call_frame&.return_pc
            next unless return_pc

            @state.pop_call
            @state.push_semantic_frame(ExecutionState::SemanticFrame.new(
                                         pc: return_pc, cursor: position, captures: state,
                                         flags: frame_flags
                                       ))
          when :split
            # Keep ordered alternatives in the VM state. The semantic frame
            # stack executes the first branch; points resume alternatives.
            instruction.target.drop(1).reverse_each do |target|
              @state.push_backtrack_point(target, cursor: position,
                                                  captures: state.dup, flags: frame_flags)
            end
            target = instruction.target.first
            @state.push_semantic_frame(ExecutionState::SemanticFrame.new(
                                         pc: target, cursor: position, captures: state.dup, flags: frame_flags
                                       ))
          when :jump
            @state.push_semantic_frame(ExecutionState::SemanticFrame.new(
                                         pc: instruction.target, cursor: position, captures: state, flags: frame_flags
                                       ))
          when :consume, :fold_boundary, :consume_class, :consume_property, :consume_escape, :consume_any,
               :assert_anchor
            boundary_metadata = instruction.opcode == :fold_boundary ?
                                @flat_program.boundary_metadata(pc) : nil
            node = boundary_metadata&.literal || @flat_program.operand(instruction.operand)
            semantic_label = [flat_transition_opcode(instruction.opcode, node), node]
            matches = transition_results(semantic_label, characters, position, state, frame_flags)
            next_instruction = if boundary_metadata&.next_pc
                                 @flat_program.instruction_at(boundary_metadata.next_pc)
                               else
                                 next_pc = (pc + 1...@flat_program.instructions.length).find do |index|
                                   @flat_program.opcode_at(index) != :scope_end
                                 end
                                 next_pc && @flat_program.instruction_at(next_pc)
                               end
            matches = reject_flat_fold_boundary_matches(
              matches, instruction.opcode, node, next_instruction, boundary_metadata,
              characters, position, frame_flags
            )
            matches = reject_flat_negated_class_suffix_matches(
              matches, pc, node, characters, position, frame_flags
            )
            matches.reverse_each do |length, inner|
              next_state = state.merge(inner || {})
              if node.is_a?(SemanticBytecode::Escape) && node.kind == :match_reset
                next_state[:__match_start] = position
                next_state[:__match_reset] = true
              end
              captures_for(semantic_label, position, length, next_state, characters, frame_flags)
              @state.push_semantic_frame(ExecutionState::SemanticFrame.new(
                                           pc: pc + 1, cursor: position + length, captures: next_state, flags: frame_flags
                                         ))
            end
            resume_backtrack if matches.empty?
          when :backreference
            node = @flat_program.operand(instruction.operand)
            semantic_label = [:match_backreference, node]
            matches = transition_results(semantic_label, characters, position, state, frame_flags)
            matches.reverse_each do |length, inner|
              @state.push_semantic_frame(ExecutionState::SemanticFrame.new(
                                           pc: pc + 1, cursor: position + length, captures: state.merge(inner || {}), flags: frame_flags
                                         ))
            end
            resume_backtrack if matches.empty?
          when :assert
            assertion = @flat_program.operand(instruction.operand)
            assertion_states = flat_assertion_capture_matches(assertion, characters, position, state, frame_flags)
            if assertion_states.any?
              assertion_states.reverse_each do |assertion_state|
                @state.push_semantic_frame(ExecutionState::SemanticFrame.new(
                                             pc: pc + 1, cursor: position,
                                             captures: assertion_state, flags: frame_flags
                                           ))
              end
            else
              resume_backtrack
            end
          when :conditional
            conditional = @flat_program.operand(instruction.operand)
            condition = conditional.condition.is_a?(Array) ? conditional.condition.first : conditional.condition
            branch = state.key?(condition) && state[condition]
            target = branch ? instruction.target[0] : instruction.target[1]
            if target
              @state.push_semantic_frame(ExecutionState::SemanticFrame.new(
                                           pc: target, cursor: position, captures: state, flags: frame_flags
                                         ))
            else
              resume_backtrack
            end
          when :fail
            # A failed branch has no continuation. The next semantic frame
            # already contains the rollback snapshot for ordered choice.
            next
          when :repeat
            quantifier = @flat_program.operand(instruction.operand)
            lengths = quantifier_lengths(quantifier, characters, position, state, frame_flags)
            lengths = reject_flat_scoped_unicode_optional_suffix_lengths(
              lengths, quantifier, pc, position, characters, frame_flags
            )
            if lengths.empty?
              resume_backtrack
              next
            end
            @state.with_repeat_frame(pc: pc, cursor: position, lengths: lengths.reverse,
                                     minimum: quantifier.minimum, maximum: quantifier.maximum) do |repeat|
              lazy_exact_capture_probe = quantifier.lazy_exact && pc.positive? &&
                                         @flat_program.opcode_at(pc - 1) == :capture_start
              lazy_probe = if lazy_exact_capture_probe
                             lengths.reverse.find(&:positive?) || 0
                           else
                             0
                           end
              repeat.lengths = [0] if lazy_exact_capture_probe
              while repeat.next_index < repeat.lengths.length
                length = repeat.lengths[repeat.next_index]
                repeat.next_index += 1
                next_state = state.dup
                label = [:match_quantifier, quantifier]
                captures_for(label, position, length, next_state, characters, frame_flags)
                continuation_cursor = position + (length.zero? ? lazy_probe : length)
                if lazy_exact_capture_probe && length.zero?
                  next_state[:__match_start] = continuation_cursor
                  next_state[:__match_reset] = true
                end
                @state.push_semantic_frame(ExecutionState::SemanticFrame.new(
                                             pc: pc + 1, cursor: continuation_cursor, captures: next_state,
                                             flags: frame_flags
                                           ))
              end
            end
          when :repeat_nullable_group
            quantifier = @flat_program.operand(instruction.operand)
            lengths = nullable_group_repeat_lengths(
              quantifier, quantifier.body, characters, position, state, frame_flags
            )
            if lengths.empty?
              resume_backtrack
              next
            end
            ordered_lengths = quantifier.body.mode == :greedy ? lengths.sort : lengths.sort.reverse
            @state.with_repeat_frame(pc: pc, cursor: position, lengths: ordered_lengths,
                                     minimum: quantifier.minimum, maximum: quantifier.maximum) do |repeat|
              while repeat.next_index < repeat.lengths.length
                length = repeat.lengths[repeat.next_index]
                repeat.next_index += 1
                next_state = state.dup
                if quantifier.number
                  capture_position = quantifier.body.mode == :greedy ? position + length : position
                  next_state[quantifier.number] = [capture_position, capture_position]
                  next_state[quantifier.name] = [capture_position, capture_position] if quantifier.name
                end
                @state.push_semantic_frame(ExecutionState::SemanticFrame.new(
                                             pc: pc + 1, cursor: position + length,
                                             captures: next_state, flags: frame_flags
                                           ))
              end
            end
          when :repeat_nested_possessive
            quantifier = @flat_program.operand(instruction.operand)
            if quantifier.body.expression.is_a?(SemanticBytecode::Any) ||
               quantifier.body.expression.is_a?(SemanticBytecode::CharacterClass) ||
               quantifier.body.expression.is_a?(SemanticBytecode::Escape) ||
               quantifier.body.expression.is_a?(SemanticBytecode::Property)
              consumed = 0
              loop do
                length = quantifier_lengths(quantifier.body, characters, position + consumed,
                                            state, frame_flags).first
                break unless length&.positive?

                consumed += length
              end
              @state.push_semantic_frame(ExecutionState::SemanticFrame.new(
                                           pc: pc + 1, cursor: position + consumed,
                                           captures: state, flags: frame_flags
                                         ))
              next
            end
            lengths = quantifier_lengths(quantifier.body, characters, position, state, frame_flags)
            if lengths.any?
              lengths.reverse_each do |length|
              @state.push_semantic_frame(ExecutionState::SemanticFrame.new(
                                           pc: pc + 1, cursor: position + length,
                                           captures: state, flags: frame_flags
                                         ))
              end
            else
              resume_backtrack
            end
          when :repeat_alternation_group
            repeat = @flat_program.operand(instruction.operand)
            consumed = 0
            captures = state.dup
            loop do
              matches = repeat.variants.flat_map do |variant|
                transition_results([semantic_opcode(variant), variant], characters,
                                    position + consumed, captures, frame_flags).map do |length, inner|
                  [length, inner]
                end
              end
              positive = matches.select { |length, _inner| length.positive? }.max_by(&:first)
              if positive
                length, inner = positive
                consumed += length
                captures.merge!(inner || {})
                captures[repeat.number] = [position + consumed - length, position + consumed]
                captures[repeat.name] = captures[repeat.number] if repeat.name
                next
              end
              zero = matches.find { |length, _inner| length.zero? }
              if zero
                captures[repeat.number] = [position + consumed, position + consumed]
                captures[repeat.name] = captures[repeat.number] if repeat.name
              end
              break
            end
            if consumed.positive? || repeat.minimum.zero?
              @state.push_semantic_frame(ExecutionState::SemanticFrame.new(
                                           pc: pc + 1, cursor: position + consumed,
                                           captures: captures, flags: frame_flags
                                         ))
            else
              resume_backtrack
            end
          when :repeat_absence
            quantifier = @flat_program.operand(instruction.operand)
            lengths = flat_absence_repeat_lengths(quantifier, characters, position, state, frame_flags)
            if lengths.empty?
              resume_backtrack
              next
            end
            @state.with_repeat_frame(pc: pc, cursor: position, lengths: lengths.reverse,
                                     minimum: quantifier.minimum, maximum: quantifier.maximum) do |repeat|
              while repeat.next_index < repeat.lengths.length
                length = repeat.lengths[repeat.next_index]
                repeat.next_index += 1
                @state.push_semantic_frame(ExecutionState::SemanticFrame.new(
                                             pc: pc + 1, cursor: position + length,
                                             captures: state.dup, flags: frame_flags
                                           ))
              end
            end
          when :repeat_zero_width
            quantifier = @flat_program.operand(instruction.operand)
            body = quantifier.predicate
            matched_all = quantifier.minimum.times.all? do
              matched = if body.is_a?(SemanticBytecode::Assertion)
                          flat_assertion_match?(body, characters, position, state, frame_flags)
                        elsif body.is_a?(SemanticBytecode::Anchor)
                          anchor_length(body, characters, position)
                        else
                          transition_results([:match_escape, body], characters, position, state, frame_flags).any?
                        end
              matched
            end
            next unless matched_all

            next_state = state.dup
            next_state[quantifier.number] = [position, position] if quantifier.capture
            next_state[quantifier.name] = [position, position] if quantifier.capture && quantifier.name
            @state.push_semantic_frame(ExecutionState::SemanticFrame.new(
                                         pc: pc + 1, cursor: position, captures: next_state,
                                         flags: frame_flags
                                       ))
          when :repeat_possessive
            quantifier = @flat_program.operand(instruction.operand)
            length = quantifier_lengths(quantifier, characters, position).first
            next unless length

            next_state = state.dup
            group = quantifier.expression
            unit = literal_value(group.body)&.length
            start = unit&.positive? ? position + length - unit : position
            next_state[group.number] = [start, position + length]
            next_state[group.name] = [start, position + length] if group.name
            @state.push_semantic_frame(ExecutionState::SemanticFrame.new(
                                         pc: pc + 1, cursor: position + length, captures: next_state,
                                         flags: frame_flags
                                       ))
          when :absence
            absence = @flat_program.operand(instruction.operand)
            outcomes = @state.with_absence_frame(
              resume_pc: pc + 1,
              body_pc: instruction.operand,
              absent_start: position,
              absent_end: characters.length,
              probe_position: position,
              possible_points: [],
              body_checkpoints: [],
              capture_checkpoints: []
            ) do
              if absence.is_a?(SemanticBytecode::AbsenceProbe)
                flat_absence_probe_results(absence.program, characters, position, state, frame_flags,
                                           capture_program: absence.capture_program,
                                           capture_requires_end: absence.capture_requires_end)
              elsif absence.is_a?(SemanticBytecode::AbsenceNullableCapture)
                flat_nullable_capture_absence_results(absence, characters, position, state, frame_flags)
              elsif absence.is_a?(SemanticBytecode::AbsenceAssertion)
                flat_absence_assertion_results(absence.assertion, characters, position, frame_flags)
              elsif absence.is_a?(SemanticBytecode::AbsenceNullableRepeat)
                flat_nullable_absence_repeat_results(absence.atom, characters, position, frame_flags)
              elsif absence.is_a?(SemanticBytecode::AbsenceRepeat)
                flat_quantified_absence_lengths(absence, characters, position, frame_flags)
              else
                flat_literal_absence_results(absence, characters, position, state, frame_flags)
              end
            end
            unless outcomes
              resume_backtrack
              next
            end

            outcomes.reverse_each do |length, absence_captures|
              if absence_captures&.key?(:__match_start) &&
                 @flat_program.instruction_at(pc + 1)&.opcode != :accept
                next
              end
              next_state = state.merge(absence_captures || {})
              captures_for([:match_absence, absence], position, length, next_state, characters, frame_flags) unless
                absence.is_a?(SemanticBytecode::AbsenceRepeat) ||
                  absence.is_a?(SemanticBytecode::AbsenceNullableRepeat) ||
                  absence.is_a?(SemanticBytecode::AbsenceNullableCapture) ||
                  absence.is_a?(SemanticBytecode::AbsenceAssertion) ||
                  absence.is_a?(SemanticBytecode::AbsenceProbe)
              @state.push_semantic_frame(ExecutionState::SemanticFrame.new(
                                           pc: pc + 1, cursor: position + length, captures: next_state,
                                           flags: frame_flags
                                         ))
            end
          when :scope_start
            option_group = @flat_program.operand(instruction.operand)
            saved = state.dup
            saved[[:__flat_scope, instruction.operand]] = frame_flags
            scoped = frame_flags.dup
            scoped[:ignorecase] = option_group.ignorecase unless option_group.ignorecase.nil?
            scoped[:multiline] = option_group.multiline unless option_group.multiline.nil?
            @state.push_semantic_frame(ExecutionState::SemanticFrame.new(
                                         pc: pc + 1, cursor: position, captures: saved, flags: scoped
                                       ))
          when :scope_end
            key = [:__flat_scope, instruction.operand]
            previous = state[key]
            next_state = state.dup
            next_state.delete(key)
            @state.push_semantic_frame(ExecutionState::SemanticFrame.new(
                                         pc: pc + 1, cursor: position, captures: next_state,
                                         flags: previous || frame_flags
                                       ))
          when :atomic_start
            next_state = state.dup
            next_state[[:__flat_atomic, instruction.operand]] = [@state.semantic_stack.length,
                                                                 @state.backtracks.length]
            @state.push_semantic_frame(ExecutionState::SemanticFrame.new(
                                         pc: pc + 1, cursor: position, captures: next_state,
                                         flags: frame_flags
                                       ))
          when :atomic_end
            depth, backtrack_depth = Array(state[[:__flat_atomic, instruction.operand]])
            next_state = state.dup
            next_state.delete([:__flat_atomic, instruction.operand])
            @state.semantic_stack.slice!(depth, @state.semantic_stack.length - depth) if depth
            @state.backtracks.slice!(backtrack_depth, @state.backtracks.length - backtrack_depth) if backtrack_depth
            @state.push_semantic_frame(ExecutionState::SemanticFrame.new(
                                         pc: pc + 1, cursor: position, captures: next_state,
                                         flags: frame_flags
                                       ))
          when :capture_start
            next_state = state.dup
            @state.start_capture(number: instruction.target, start: position)
            @state.push_semantic_frame(ExecutionState::SemanticFrame.new(
                                         pc: pc + 1, cursor: position, captures: next_state, flags: frame_flags
                                       ))
          when :capture_end
            next_state = state.dup
            number, name = instruction.target
            capture_frame = @state.active_capture_frame(number)
            if capture_frame&.number == number
              capture_frame.name = name
              @state.commit_capture(next_state, capture_frame, finish: position)
              @state.push_semantic_frame(ExecutionState::SemanticFrame.new(
                                           pc: pc + 1, cursor: position, captures: next_state, flags: frame_flags
                                         ))
            end
          when :nop
            @state.push_semantic_frame(ExecutionState::SemanticFrame.new(
                                         pc: pc + 1, cursor: position, captures: state, flags: frame_flags
                                       ))
          end

        end
        @state.backtracks.clear
        @state.capture_frames.clear
        results
      end

      def reject_flat_scoped_unicode_optional_suffix_lengths(lengths, quantifier, program_counter,
                                                             position, characters, flags)
        return lengths unless quantifier.is_a?(SemanticBytecode::Quantifier)
        return lengths unless quantifier.minimum.zero? && quantifier.maximum == 1
        return lengths unless flags[:ignorecase]

        body = quantifier.expression
        body = body.parts.first if body.is_a?(SemanticBytecode::Sequence) && body.parts.one?
        return lengths unless body.is_a?(SemanticBytecode::Literal)
        return lengths if body.value.ascii_only? || body.value.downcase(:fold) == body.value
        return lengths unless characters[position] == body.value

        next_pc = (program_counter + 1...@flat_program.instructions.length).find do |index|
          @flat_program.opcode_at(index) != :scope_end
        end
        return lengths unless next_pc && @flat_program.opcode_at(next_pc) != :accept

        lengths.reject { |length| length == body.value.length }
      end

      def semantic_opcode(node)
        case node
        when SemanticBytecode::Literal then :match_literal
        when SemanticBytecode::AlternationAtom then :match_alternation_atom
        when SemanticBytecode::CharacterClass then :match_class
        when SemanticBytecode::Property then :match_property
        when SemanticBytecode::Escape then :match_escape
        when SemanticBytecode::Any then :match_any
        when SemanticBytecode::Anchor then :test_anchor
        when SemanticBytecode::Group then :match_group
        when SemanticBytecode::OptionGroup then :match_option_group
        when SemanticBytecode::AtomicGroup then :match_atomic_group
        when SemanticBytecode::Quantifier then :match_quantifier
        when SemanticBytecode::Assertion then :match_assertion
        when SemanticBytecode::Backreference then :match_backreference
        when SemanticBytecode::Conditional then :match_conditional
        when SemanticBytecode::SubexpressionCall then :match_subexpression_call
        when SemanticBytecode::Absence then :match_absence
        else :semantic
        end
      end

      def resume_backtrack
        !@state.resume_backtrack.nil?
      end

      # Map a flat VM operation to the primitive semantic matcher.
      # The VM dispatches by instruction kind, while the matcher keeps one
      # stable transition interface for the compatibility and flat paths.
      def flat_transition_opcode(opcode, node)
        case opcode
        when :consume, :fold_boundary then :match_literal
        when :consume_class then :match_class
        when :consume_property then :match_property
        when :consume_escape then :match_escape
        when :consume_any then :match_any
        when :assert_anchor then :test_anchor
        else semantic_opcode(node)
        end
      end

      def reject_flat_fold_boundary_matches(matches, opcode, node, next_instruction, metadata = nil,
                                            characters = nil, position = nil, flags = {})
        return matches unless node.is_a?(SemanticBytecode::Literal)
        boundary_sensitive = node.fold_boundary_sensitive || metadata&.expanded_tail?
        unless opcode == :fold_boundary || boundary_sensitive
          return reject_flat_reverse_fold_suffix_matches(matches, node, next_instruction,
                                                         characters, position, flags)
        end

        anchor = if next_instruction&.opcode == :assert_anchor
                   @flat_program.operand(next_instruction.operand)
                 elsif next_instruction&.opcode == :assert
                   assertion = @flat_program.operand(next_instruction.operand)
                   assertion.flat_atoms&.first if assertion.is_a?(SemanticBytecode::Assertion) &&
                                                  assertion.kind == :positive
                 end
        if metadata&.expanded_tail? && metadata.tail_matches_any_next_fold? &&
           %i[consume fold_boundary].include?(next_instruction&.opcode) && characters && position
          remaining = characters.length - position
            return matches.reject do |length, _inner|
              metadata.source_width_match?(length) &&
              metadata.matching_next_fold_width_delta?(remaining - length, 0)
            end
        end
        return matches unless anchor.is_a?(SemanticBytecode::Anchor) &&
                              anchor.kind == :anchor_absolute_end

        matches.reject do |length, _inner|
          metadata ? metadata.source_width_match?(length) : length == node.source_width
        end
      end

      def reject_flat_reverse_fold_suffix_matches(matches, node, next_instruction, characters, position, flags)
        return matches unless flags[:ignorecase] && characters && position
        if next_instruction&.opcode == :jump && next_instruction.target.is_a?(Integer)
          next_pc = next_instruction.target
          next_pc += 1 while @flat_program.opcode_at(next_pc) == :scope_end
          next_instruction = @flat_program.instruction_at(next_pc)
        elsif next_instruction&.opcode == :scope_end
          next_pc = @flat_program.instructions.index(next_instruction) + 1
          next_pc += 1 while @flat_program.opcode_at(next_pc) == :scope_end
          next_instruction = @flat_program.instruction_at(next_pc)
        end
        return matches unless %i[consume fold_boundary].include?(next_instruction&.opcode)
        suffix = @flat_program.operand(next_instruction.operand)
        return matches unless suffix.is_a?(SemanticBytecode::Literal)
        return matches unless node.casefold && node.value.each_char.one? && node.casefold.each_char.one?
        return matches unless node.value != node.casefold && characters[position] == node.value
        return matches unless suffix.value.downcase(:fold) != node.casefold
        return matches unless Onibi::UnicodeProperties.reverse_casefold_variants(node.casefold).include?(node.value)

        matches.reject { |length, _inner| length == node.source_width }
      end

      def reject_flat_negated_class_suffix_matches(matches, program_counter, node, characters, position, flags)
        return matches unless flags[:ignorecase] && node.is_a?(SemanticBytecode::Literal)
        return matches unless node.value.ascii_only? && characters && position
        return matches unless characters[position] && characters[position] != node.value &&
                              characters[position].downcase == node.value.downcase

        scope_pc = program_counter - 1
        repeat_pc = scope_pc - 1
        return matches unless scope_pc >= 0 && repeat_pc >= 0
        return matches unless @flat_program.opcode_at(scope_pc) == :scope_start &&
                              @flat_program.opcode_at(repeat_pc) == :repeat

        quantifier = @flat_program.operand(@flat_program.instruction_at(repeat_pc).operand)
        expression = quantifier.expression if quantifier.is_a?(SemanticBytecode::Quantifier)
        return matches unless expression.is_a?(SemanticBytecode::CharacterClass) &&
                              expression.value.start_with?("^")

        []
      end

      # Match a compile-time flat atom list without entering tree_results.
      # Return nil when the assertion has no flat atom representation.
      def flat_assertion_match?(assertion, characters, cursor, captures, flags)
        !flat_assertion_capture_matches(assertion, characters, cursor, captures, flags).empty?
      end

      def flat_assertion_capture_match(assertion, characters, cursor, captures, flags)
        flat_assertion_capture_matches(assertion, characters, cursor, captures, flags).first
      end

      def flat_assertion_capture_matches(assertion, characters, cursor, captures, flags)
        atoms = assertion.flat_atoms
        return [] unless atoms

        variants = atoms.first.is_a?(Array) ? atoms : [atoms]
        lookbehind = %i[positive_lookbehind negative_lookbehind].include?(assertion.kind)
        matched = if lookbehind
                    Array(assertion.widths).flat_map do |width|
                      next [] unless width.is_a?(Integer) && width <= cursor

                      flat_assertion_results(variants, characters, cursor - width, captures, flags).filter_map do |length, state|
                        state if length == width
                      end
                    end
                  else
                    flat_assertion_results(variants, characters, cursor, captures, flags).map(&:last)
                  end
        negative = %i[negative negative_lookahead negative_lookbehind].include?(assertion.kind)
        if negative
          matched.empty? ? [captures] : []
        else
          matched
        end
      end

      def flat_assertion_results(variants, characters, cursor, captures, flags)
        variants.flat_map do |atoms|
          Array(atoms).reduce([[0, captures]]) do |partial, atom|
            partial.flat_map do |consumed, current_captures|
              position = cursor + consumed
              case atom
              when SemanticBytecode::CaptureAtom
                nested_variants = atom.atoms.first.is_a?(Array) ? atom.atoms : [atom.atoms]
                nested = flat_assertion_results(nested_variants, characters, position,
                                                current_captures, flags)
                nested.map do |length, nested_captures|
                  updated = nested_captures.dup
                  span = [position, position + length]
                  updated[atom.number] = span
                  updated[atom.name] = span if atom.name
                  [consumed + length, updated]
                end
              when SemanticBytecode::RepeatAtom
                repeat_variants = atom.atoms.first.is_a?(Array) ? atom.atoms : [atom.atoms]
                zero_results = flat_assertion_results(repeat_variants, characters, position,
                                                      current_captures, flags).select { |length, _state| length.zero? }
                if zero_results.any?
                  zero_limit = atom.maximum || atom.minimum
                  zero_limit = [zero_limit, 32].min
                  zero_state = zero_results.first.last
                  (atom.minimum..zero_limit).map do |_count|
                    [consumed, zero_state]
                  end
                else
                  frontier = [[0, current_captures, 0]]
                  candidates = []
                  limit = atom.maximum || (characters.length - position)
                  while frontier.any?
                    expanded = frontier.flat_map do |total, repeat_captures, count|
                      next [] if count >= limit

                      flat_assertion_results(repeat_variants, characters, position + total,
                                             repeat_captures, flags).filter_map do |length, nested_captures|
                        next if length.zero? || total + length > limit

                        [total + length, nested_captures, count + 1]
                      end
                    end
                    break if expanded.empty?

                    candidates.concat(expanded)
                    frontier = expanded
                  end
                  ordered = candidates.select { |_total, _state, count| count >= atom.minimum }
                  ordered.sort_by! { |total, _state, _count| atom.mode == :lazy ? total : -total }
                  ordered = ordered.first(1) if atom.mode == :possessive
                  ordered.map { |total, repeat_captures, _count| [consumed + total, repeat_captures] }
                end
              when SemanticBytecode::AssertionAtom
                nested = flat_assertion_capture_matches(atom, characters, position,
                                                        current_captures, flags)
                nested.map { |nested_captures| [consumed, nested_captures] }
              when SemanticBytecode::ConditionalAtom
                condition = atom.condition.is_a?(Array) ? atom.condition.first : atom.condition
                branch = current_captures.key?(condition) ? atom.yes_atoms : atom.no_atoms
                nested_variants = branch.first.is_a?(Array) ? branch : [branch]
                flat_assertion_results(nested_variants, characters, position,
                                       current_captures, flags).map do |length, nested_captures|
                  [consumed + length, nested_captures]
                end
              else
                label = [semantic_opcode(atom), atom]
                transition_lengths(label, characters, position, current_captures, flags).filter_map do |width|
                  next unless width && width >= 0

                  [consumed + width, current_captures]
                end
              end
            end
          end
        end.uniq
      end

      def flat_assertion_lengths(variants, characters, cursor, captures, flags)
        variants.flat_map do |atoms|
          atoms.reduce([0]) do |partial, atom|
            partial.flat_map do |consumed|
              position = cursor + consumed
              label = [semantic_opcode(atom), atom]
              transition_lengths(label, characters, position, captures, flags).filter_map do |width|
                next unless width && width >= 0

                consumed + width
              end
            end.uniq
          end
        end.uniq
      end

      def expanded_fold_tail_rejected?(captures, characters, cursor)
        captured_fold = captures[:__captured_expanded_fold]
        return false unless captures[:__expanded_fold_anchor] || captured_fold

        source_fold = captures[:__group_expanded_literal_fold]
        prefix = captures[:__group_expanded_literal_prefix] || +""
        return false unless source_fold && prefix && source_fold.start_with?(prefix) && source_fold != prefix
        return false unless captures[:__group_expanded_literal_boundary]
        return false if captures[:__group_expanded_literal_boundary][:kind] == :simple_fold_source

        remaining = characters.drop(cursor).map { |character| character.downcase(:fold) }.join
        if captured_fold
          boundary = captures[:__group_expanded_literal_boundary]
          return false unless boundary && boundary[:kind] == :expanded_tail

          return true if captures[:__captured_fold_incompatible]
          return true if remaining.empty? && prefix.length.positive?

          return remaining.start_with?(source_fold[prefix.length..])
        end
        return true if remaining.start_with?(source_fold[prefix.length..])

        tail = source_fold[prefix.length..]
        return false if tail&.each_char&.all? { |character| Onibi::UnicodeProperties.mark?(character) }
        return true if prefix.empty?

        !remaining.empty? || source_fold != prefix * (source_fold.length / prefix.length)
      end

      def shifted_absence_suffix?(node)
        # Semantic operand transition:
        #   input  = <operand, cursor, captures, flags>
        #   output = ordered [[length, next_captures], ...]
        # Sequence, alternation, and quantifier operands may push several
        # candidates. The caller owns candidate selection and cursor advance.
        case node
        when SemanticBytecode::Sequence
          # sequence: run each child from the prior result cursor. A child
          # failure removes only that candidate; other candidates backtrack.
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

      # Execute the automaton bytecode through one dispatcher.  DFA and TNFA
      # differ only in the instruction that supplies outgoing edges; their
      # candidate stack, capture state, ordered choice, and match-reset rule
      # are identical.
      #
      # Formal transitions:
      #   :match      [label, target_state] -> consume, then :jump(target)
      #   :nfa_match  edge(from, to, operation) -> consume, then continue at
      #               edge.to
      #   :accept/:nfa_accept -> halt with the current [start, cursor, state]
      #
      # State transition notation:
      #   input  = <state, cursor, captures, flags>
      #   result = [length, next_captures]
      #   success = <target, cursor + length, captures merged with result>
      #   failure = input state is restored before the next edge is tried
      # `transition_results` owns the result stack. This loop owns cursor,
      # local-state merge, ordered edge selection, and control-state advance.
      #
      # The `case` below is the VM's automaton opcode dispatch.  Semantic
      # operands are dispatched by `transition_results` after this point.
      def walk_bytecode(state, characters, cursor, captures, start, flags)
        @state.push_vm_frame(ExecutionState::VMFrame.new(
                               state: state, cursor: cursor, captures: captures, start: start,
                               edges: nil, edge_index: 0
                             ))
        until @state.vm_stack.empty?
          @state.steps += 1
          return nil if @state.steps > 2_000_000

          frame = @state.vm_stack.last
          if frame.edges.nil?
            if (@automaton_mode == :dfa && accepting?(frame.state)) ||
               (@automaton_mode == :nfa && tnfa_accepting?(frame.state))
              return [frame.start, frame.cursor, frame.captures]
            end

            edges = if @automaton_mode == :dfa
                      transitions_for(frame.state)
                    elsif @automaton_mode == :nfa
                      transitions_for_tnfa(frame.state).map do |edge|
                        [[edge.operation.opcode, edge.operation.operand], edge.to, edge.respond_to?(:tags) ? edge.tags : []]
                      end
                    else
                      []
                    end
            frame.edges = edges
          end

          if frame.edge_index >= frame.edges.length
            @state.pop_vm_frame
            next
          end

          label, target, tags = frame.edges[frame.edge_index]
          frame.edge_index += 1
          results = transition_results(label, characters, frame.cursor, frame.captures, flags)
          results.reverse_each do |length, inner_captures|
            next_captures = frame.captures.dup
            next_captures.merge!(inner_captures)
            captures_for(label, frame.cursor, length, next_captures, characters, flags)
            apply_tag_effects(tags, label, frame.cursor, length, next_captures)
            next_start = if label[0] == :match_escape && label[1].kind == :match_reset
                           frame.cursor
                         else
                           frame.start
                         end
            @state.push_vm_frame(ExecutionState::VMFrame.new(
                                   state: target, cursor: frame.cursor + length,
                                   captures: next_captures, start: next_start,
                                   edges: nil, edge_index: 0
                                 ))
          end
        end
        nil
      end

      def transition_results(label, characters, cursor, captures, flags = {})
        # Semantic dispatch transition:
        #   input  = <opcode, operand, cursor, captures, flags>
        #   output = ordered operand-stack values [[length, next_captures], ...]
        # A zero-width operand pushes length `0`; a failed operand pushes no
        # value. The caller owns cursor advancement and local-state merge.
        opcode, operand = label
        case opcode
        when :epsilon
          # epsilon: <cursor, locals> -> [[0, locals]]
          [[0, {}]]
        when :match_group
          # group: evaluate the body in the current scope.
          tree_results(operand.body, characters, cursor, captures, flags)
        when :match_atomic_group
          # atomic_group: evaluate the body, then commit its first candidate.
          tree_results(operand.body, characters, cursor, captures, flags).first(1)
        when :match_option_group
          # option_group: evaluate the body with scoped flags. The outer
          # flags remain unchanged after this result returns.
          tree_results(operand.body, characters, cursor, captures,
                       flags.merge(ignorecase: operand.ignorecase, multiline: operand.multiline))
        when :match_quantifier
          # quantifier: push ordered repetition candidates and captures.
          quantifier_results(operand, characters, cursor, captures, flags)
        when :match_assertion
          # assertion: push only zero-width candidates; cursor is preserved.
          assertion_results(operand, characters, cursor, captures, flags)
        when :match_subexpression_call
          # subexpression_call: invoke the compiled target and merge its state.
          tree_results(operand, characters, cursor, captures, flags)
        when :match_absence
          # absence: probe the bounded complement. Each result carries its
          # length and the frame-restored local state.
          absence_results(operand, characters, cursor, captures, flags)
        when :match_alternation_atom
          flat_assertion_lengths(operand.variants, characters, cursor, captures, flags).map do |length|
            [length, {}]
          end
        when :match_class
          # class: each accepted character width becomes one stack result.
          class_match_lengths(operand, characters, cursor, flags).map { |length| [length, {}] }
        when :match_property
          # property: each accepted property width becomes one stack result.
          property_match_lengths(operand, characters, cursor, flags).map { |length| [length, {}] }
        else
          # literal, escape, any, and anchor use one transition length. A nil
          # length means failure; zero means a successful zero-width operand.
          transition_lengths(label, characters, cursor, captures, flags).map { |length| [length, {}] }
        end
      end

      def assertion_results(assertion, characters, cursor, captures, flags = {})
        # Assertion transition:
        #   input  = <assertion, cursor, captures, flags>
        #   success = [[0, next_captures]]
        #   failure = []
        # The input cursor never changes. Captures written by a positive
        # assertion are returned as local state, but the caller advances by 0.
        if %i[positive positive_lookahead].include?(assertion.kind)
          lookahead_captures = captures.merge(__fold_lookahead_operand: true)
          results = tree_results(assertion.body, characters, cursor, lookahead_captures, flags).first(1).map do |_length, inner|
            inner = inner.dup
            inner.delete(:__fold_lookahead_operand)
            # Keep a boundary marker when the lookahead consumed a source
            # character that expands to multiple folded characters.  The
            # zero-width assertion must not donate that expansion to the
            # following consuming operand.
            expanded_fold = inner[:__expanded_literal_fold] ||
                            inner[:__group_expanded_literal_fold] ||
                            inner[:__captured_expanded_fold]
            boundary = inner[:__expanded_literal_boundary] || inner[:__group_expanded_literal_boundary]
            inner[:__fold_lookahead_expanded] = expanded_fold if expanded_fold && expanded_fold.length > 1 && boundary&.fetch(:sensitive, false)
            boundary = fold_boundary_for_node(assertion.body)
            inner[:__fold_lookahead_expanded] ||= true if flags[:ignorecase] &&
                                                          boundary&.fetch(:sensitive, false)
            [0, inner]
          end
          return mark_end_zero_width(results, characters, cursor, flags)
        end

        if %i[negative negative_lookahead].include?(assertion.kind)
          matched = tree_results(assertion.body, characters, cursor, captures, flags).any?
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
          folded_widths = assertion.folded_widths || casefold_widths(assertion.body)
          widths = folded_widths unless folded_widths.empty?
        end
        lookbehind_flags = flags.merge(lookbehind_casefold: true, lookbehind_fold_source: true)
        # The loop carries all branch-specific fold metadata into VM state.
        # rubocop:disable Metrics/BlockLength
        widths.select { |width| width <= cursor }.sort.reverse_each do |width|
          results = tree_results(assertion.body, characters, cursor - width, captures, lookbehind_flags)
          matching = results.select { |length, _inner| length == width }
          if flags[:ignorecase] && cursor < characters.length &&
             expanded_lookbehind_source_at_boundary?(assertion.body, characters, cursor)
            matching = []
          end
          unless matching.empty?
            return matching.map do |_length, inner|
              state = inner.dup
              expanded_source = characters[cursor - width]
              if flags[:ignorecase] && expanded_source && width == expanded_source.length &&
                 expanded_source.downcase(:fold).length > expanded_source.length &&
                 folded_lookbehind_values(assertion.body).any? { |value| casefold_equal?(value, expanded_source) }
                state[:__defer_expanded_match] = true
              end
              state[:__lookbehind_simple_fold_source] = true if
                state[:__expanded_literal_boundary]&.fetch(:kind, nil) == :simple_fold_source
              state[:__lookbehind_reverse_fold] = true if flags[:ignorecase] && cursor == characters.length &&
                                                          expanded_lookbehind_source?(assertion.body, characters, cursor)
              [0, state]
            end
          end

          next unless flags[:ignorecase] && lookbehind_fold_overlap?(assertion.body)

          folded_width = folded_widths.find { |candidate| candidate == width }
          partial = results.select do |length, state|
            candidate_width = lookbehind_result_folded_width(assertion.body, state, folded_width)
            length < width && length < candidate_width
          end
          if reverse_lookbehind_fold?(assertion.body)
            start = cursor - width
            source = characters[start]
            partial = partial.select do |length, _inner|
              gap = characters[(start + length)...cursor]
              folded_source = source&.downcase(:fold)
              folded_source && gap.all? { |character| folded_source.include?(character.downcase(:fold)) }
            end
            if partial.empty? && source
              folded_bodies = folded_lookbehind_values(assertion.body)
              partial = results.select { |length, _inner| length < width } if
                folded_bodies.any? { |body| source.downcase(:fold) == body }
            end
          end
          next if partial.empty?

          overlap = lookbehind_result_folded_width(assertion.body, partial.first.last, folded_width) - partial.first.first
          return partial.map do |_length, inner|
            state = inner.dup
            state[:__lookbehind_overlap] = overlap if overlap.positive?
            state[:__lookbehind_overlap_source] = characters[cursor - 1] if overlap.positive?
            overlap_values = lookbehind_result_values(assertion.body, inner)
            state[:__lookbehind_overlap_values] = overlap_values
            if cursor == characters.length && overlap.positive? &&
               (reverse_lookbehind_fold?(assertion.body) || expanded_lookbehind_fold?(assertion.body)) &&
               overlap_values.none? { |value| casefold_equal?(value, characters[cursor - 1]) }
              state[:__lookbehind_direct_tail_reject] = true
            end
            if assertion.body.is_a?(SemanticBytecode::Alternation)
              state[:__lookbehind_overlap_alternation] = true
              branch = assertion.body.branches[inner[:__match_alternative_index]]
              prior_branches = assertion.body.branches.first(inner[:__match_alternative_index].to_i)
              source = characters[cursor - 1].to_s.downcase(:fold)
              prior_values = prior_branches.flat_map { |prior| folded_lookbehind_values(prior) }
              state[:__lookbehind_prior_overlap_source] = true if prior_branches.any? do |prior|
                folded_lookbehind_values(prior).any? { |value| value.start_with?(source) }
              end
              state[:__lookbehind_prior_overlap_values] = prior_values unless prior_values.empty?
              state[:__lookbehind_overlap_expanded] = true if
                branch && casefold_widths(branch).max > source_widths(branch).max
              state[:__lookbehind_direct_tail_reject] = true if
                state[:__lookbehind_overlap_expanded] && cursor == characters.length
            end
            state[:__lookbehind_reverse_fold] = true if cursor == characters.length &&
                                                        (reverse_lookbehind_fold?(assertion.body) ||
                                                         expanded_lookbehind_source?(assertion.body, characters, cursor))
            [0, state]
          end
        end
        # rubocop:enable Metrics/BlockLength
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

      def source_widths(node)
        case node
        when SemanticBytecode::Literal
          [node.value.length]
        when SemanticBytecode::CharacterClass
          [1]
        when SemanticBytecode::Sequence
          node.parts.reduce([0]) do |widths, part|
            widths.product(source_widths(part)).map { |left, right| left + right }.uniq
          end
        when SemanticBytecode::Alternation
          node.branches.flat_map { |branch| source_widths(branch) }.uniq
        when SemanticBytecode::Group, SemanticBytecode::OptionGroup,
             SemanticBytecode::AtomicGroup, SemanticBytecode::Assertion
          source_widths(node.body)
        when SemanticBytecode::Quantifier
          body_widths = source_widths(node.expression)
          maximum = node.maximum || node.minimum
          (node.minimum..maximum).flat_map do |count|
            body_widths.repeated_combination(count).map(&:sum)
          end.uniq
        else
          []
        end
      end

      def lookbehind_fold_overlap?(node)
        return node.branches.all? { |branch| lookbehind_fold_overlap?(branch) } if node.is_a?(SemanticBytecode::Alternation)
        return node.minimum == node.maximum && lookbehind_fold_overlap?(node.expression) if node.is_a?(SemanticBytecode::Quantifier)
        if node.is_a?(SemanticBytecode::Sequence) && !node.parts.all? { |part| part.is_a?(SemanticBytecode::Literal) }
          return node.parts.all? { |part| lookbehind_fold_overlap?(part) }
        end

        body = node.is_a?(SemanticBytecode::Sequence) ? node.parts : [node]
        body.all? { |part| part.is_a?(SemanticBytecode::Literal) }
      end

      def clear_lookbehind_overlap_state(captures)
        next_state = captures.dup
        %i[__lookbehind_overlap __lookbehind_overlap_source __lookbehind_overlap_values
           __lookbehind_overlap_alternation __lookbehind_overlap_expanded
           __lookbehind_direct_tail_reject __lookbehind_prior_overlap_source
           __lookbehind_prior_overlap_values].each { |key| next_state.delete(key) }
        next_state
      end

      def reverse_lookbehind_fold?(node)
        return node.branches.any? { |branch| reverse_lookbehind_fold?(branch) } if node.is_a?(SemanticBytecode::Alternation)

        if node.is_a?(SemanticBytecode::Quantifier)
          return false unless node.minimum == node.maximum
          return reverse_casefold_sequence?(node.expression.value * node.minimum) if node.expression.is_a?(SemanticBytecode::Literal)

          return reverse_lookbehind_fold?(node.expression)
        end

        if node.is_a?(SemanticBytecode::Sequence) && !node.parts.all? { |part| part.is_a?(SemanticBytecode::Literal) }
          return node.parts.any? { |part| reverse_lookbehind_fold?(part) }
        end

        body = node.is_a?(SemanticBytecode::Sequence) ? node.parts : [node]
        return false unless body.all? { |part| part.is_a?(SemanticBytecode::Literal) }

        reverse_casefold_sequence?(body.map(&:value).join)
      end

      def expanded_lookbehind_fold?(node)
        return node.branches.any? { |branch| expanded_lookbehind_fold?(branch) } if node.is_a?(SemanticBytecode::Alternation)
        return node.parts.any? { |part| expanded_lookbehind_fold?(part) } if node.is_a?(SemanticBytecode::Sequence)
        return node.casefold && node.casefold.length > node.value.length if node.is_a?(SemanticBytecode::Literal)

        false
      end

      def expanded_lookbehind_source?(node, characters, cursor)
        return node.branches.any? { |branch| expanded_lookbehind_source?(branch, characters, cursor) } if node.is_a?(SemanticBytecode::Alternation)
        return node.parts.any? { |part| expanded_lookbehind_source?(part, characters, cursor) } if node.is_a?(SemanticBytecode::Sequence)
        return false unless node.is_a?(SemanticBytecode::Literal)
        return false unless node.casefold && node.casefold.length > node.value.length

        source = characters[cursor - node.casefold.length, node.value.length]
        source && source.join == node.value
      end

      def expanded_lookbehind_source_at_boundary?(node, characters, cursor)
        return node.branches.any? { |branch| expanded_lookbehind_source_at_boundary?(branch, characters, cursor) } if node.is_a?(SemanticBytecode::Alternation)
        return node.parts.any? { |part| expanded_lookbehind_source_at_boundary?(part, characters, cursor) } if node.is_a?(SemanticBytecode::Sequence)
        return false unless node.is_a?(SemanticBytecode::Literal)
        return false unless node.casefold && node.casefold.length > node.value.length

        characters[cursor - node.value.length] == node.value
      end

      def folded_lookbehind_value(node)
        return node.branches.map { |branch| folded_lookbehind_value(branch) }.compact.first if node.is_a?(SemanticBytecode::Alternation)
        return node.parts.map { |part| folded_lookbehind_value(part) }.join if node.is_a?(SemanticBytecode::Sequence)
        return folded_lookbehind_value(node.expression).to_s * node.minimum if node.is_a?(SemanticBytecode::Quantifier) && node.minimum == node.maximum
        return node.casefold || node.value.downcase(:fold) if node.is_a?(SemanticBytecode::Literal)

        nil
      end

      def folded_lookbehind_values(node)
        return node.branches.flat_map { |branch| folded_lookbehind_values(branch) } if node.is_a?(SemanticBytecode::Alternation)
        return [node.parts.flat_map { |part| folded_lookbehind_values(part) }.join] if node.is_a?(SemanticBytecode::Sequence)
        return [folded_lookbehind_values(node.expression).join * node.minimum] if node.is_a?(SemanticBytecode::Quantifier) && node.minimum == node.maximum
        return [node.casefold || node.value.downcase(:fold)] if node.is_a?(SemanticBytecode::Literal)

        []
      end

      def lookbehind_overlap_suffix?(values, source, length)
        folded_source = source.to_s.downcase(:fold)
        values.any? { |value| value.each_char.to_a.last(length).join == folded_source }
      end

      def lookbehind_overlap_quantifier_results(quantifier, characters, cursor, captures, flags)
        source = captures[:__lookbehind_overlap_source]

        clean = captures.dup
        clean.delete(:__lookbehind_overlap)
        clean.delete(:__lookbehind_overlap_source)
        clean.delete(:__lookbehind_overlap_values)
        clean.delete(:__lookbehind_overlap_alternation)
        clean.delete(:__lookbehind_overlap_expanded)
        clean.delete(:__lookbehind_direct_tail_reject)
        clean.delete(:__lookbehind_prior_overlap_source)
        clean.delete(:__lookbehind_prior_overlap_values)
        unless casefold_equal?(quantifier.expression.value, source)
          fold_suffix = Array(captures[:__lookbehind_overlap_values]).any? do |value|
            value.end_with?(source.to_s.downcase(:fold))
          end
          repeated_overlap_source = fold_suffix && source.to_s.downcase(:fold).length == 1 && cursor > 1 &&
                                    casefold_equal?(characters[cursor - 2], source)
          prior_single_source = Array(captures[:__lookbehind_prior_overlap_values]).any? do |value|
            value.each_char.to_a.length == 1 && value.start_with?(source.to_s.downcase(:fold))
          end
          return quantifier.minimum.zero? && captures[:__lookbehind_overlap_alternation] &&
                 (prior_single_source || repeated_overlap_source) ? [[0, clean]] : []
        end
        results = tree_results(quantifier, characters, cursor, clean, flags)
        if quantifier.maximum
          overlap = captures[:__lookbehind_overlap].to_i
          remaining = characters.length - cursor
          limit = remaining.zero? ? 0 : [remaining - overlap, 1].max
          results = results.select { |length, _state| length <= limit }
        end
        return results.select { |length, _state| length.zero? } if quantifier.maximum == 1 && quantifier.minimum.zero?

        results
      end

      def prior_overlap_exact?(captures, value)
        Array(captures[:__lookbehind_prior_overlap_values]).any? do |candidate|
          casefold_equal?(candidate, value)
        end
      end

      def lookbehind_result_folded_width(node, state, fallback)
        if node.is_a?(SemanticBytecode::Alternation) && state[:__match_alternative_index]
          branch = node.branches[state[:__match_alternative_index]]
          return casefold_widths(branch).max.to_i if branch
        end

        fallback.to_i
      end

      def lookbehind_result_values(node, state)
        if node.is_a?(SemanticBytecode::Alternation) && state[:__match_alternative_index]
          branch = node.branches[state[:__match_alternative_index]]
          return folded_lookbehind_values(branch) if branch
        end

        folded_lookbehind_values(node)
      end

      def literal_fold_marker(node, characters, cursor, captures, flags, length)
        return unless node.is_a?(SemanticBytecode::Literal)
        return if flags[:skip_fold_marker] || !flags[:ignorecase] || length != 1

        character = characters[cursor]
        expanded = node.casefold && node.casefold.length > node.value.length &&
                   character&.downcase(:fold) == node.casefold
        simple_source = simple_fold_source_match?(node, character) && character != node.casefold &&
                        (!node.value.ascii_only? || !character.ascii_only?)
        return unless expanded || simple_source

        captures.merge(
          __expanded_literal_source: true,
          __expanded_literal_fold: simple_source ? node.casefold : character.downcase(:fold),
          __expanded_literal_boundary: simple_fold_boundary_for(node, character) || node.fold_boundary,
          __expanded_literal_value: character
        )
      end

      # Onigmo can split one expanded fold across adjacent operands. For
      # example, `[s]s` matches one `ß` under `/i`. The normal cursor model
      # cannot split a Unicode character, so compare the operand run with its
      # virtual folded input and consume the original character width.
      def casefold_sequence_results(parts, characters, cursor, captures, flags)
        return [] unless flags[:ignorecase]

        literal_prefix = parts.take_while { |part| reverse_fold_literal_operand(part) }
        if literal_prefix.length >= 2 && reverse_fold_group_sequence_allowed?(literal_prefix)
          reverse_value = literal_prefix.map { |part| reverse_fold_literal_operand(part).value }.join
          source = characters[cursor]
          folded_source = source&.downcase(:fold)
          folded_pattern = reverse_value.downcase(:fold)
          if source && folded_source && folded_source.length > source.length &&
             folded_pattern.start_with?(folded_source) &&
             reverse_fold_sequence_compatible?(literal_prefix, folded_source)
            suffix = SemanticBytecode::Sequence.new(parts.drop(literal_prefix.length))
            lengths = casefold_lengths(reverse_value, characters, cursor, folded: folded_pattern)
            return lengths.flat_map do |width|
              tree_results(suffix, characters, cursor + width, captures, flags).map do |length, inner|
                [width + length, inner]
              end
            end
          end
        end

        prefix = []
        parts.each do |part|
          break unless (prefix.empty? && part.is_a?(SemanticBytecode::CharacterClass)) ||
                       (prefix.any? && part.is_a?(SemanticBytecode::Literal) &&
                        part.value.each_char.one?)

          prefix << part
        end
        return [] if prefix.length < 2 || prefix.first.value.start_with?("^")

        split_class = true
        if prefix.first.is_a?(SemanticBytecode::CharacterClass) && prefix.first.split_casefold
          suffix = prefix.drop(1)
          split_safe = suffix.length == 1 && suffix.first.is_a?(SemanticBytecode::Literal) &&
                       suffix.first.value.each_char.one? &&
                       (suffix.first.casefold || suffix.first.value).each_char.one?
          split_class = split_safe
        end

        maximum = [characters.length - cursor, casefold_prefix_width(prefix)].min
        1.upto(maximum).filter_map do |width|
          slice = characters[cursor, width]
          if prefix.first.is_a?(SemanticBytecode::CharacterClass) &&
             slice.first&.downcase(:fold)&.length.to_i > 1 &&
             !prefix.first.split_casefold && !singleton_character_class?(prefix.first)
            next
          end
          if prefix.first.is_a?(SemanticBytecode::CharacterClass) &&
             prefix.first.casefolds.any? &&
             slice.first.downcase(:fold).length == 1 &&
             slice.first != slice.first.downcase(:fold)
            next
          end

          folded = slice.join.downcase(:fold)
          expanded_class = prefix.first.is_a?(SemanticBytecode::CharacterClass) && prefix.first.split_casefold
          expected_fold_characters = prefix.flat_map do |part|
            if part.is_a?(SemanticBytecode::Literal)
              (part.casefold || part.value).each_char.to_a
            else
              class_fold_characters(part)
            end
          end.uniq
          next unless folded.each_char.all? { |character| expected_fold_characters.include?(character) }
          next unless fold_sequence_expansion_boundaries_valid?(prefix, slice)
          next unless folded_atoms_match?(prefix, folded, flags, allow_fold_tail: expanded_class,
                                                                 split_class: split_class)

          next [[width, captures.dup]] if prefix.length == parts.length

          suffix = SemanticBytecode::Sequence.new(parts.drop(prefix.length))
          tree_results(suffix, characters, cursor + width, captures, flags).map do |length, inner|
            [width + length, inner]
          end
        end.flatten(1)
      end

      def reverse_fold_literal_operand(node)
        return node if node.is_a?(SemanticBytecode::Literal)
        return if node.is_a?(SemanticBytecode::Group) && node.capture

        body = if node.is_a?(SemanticBytecode::Group) ||
                  node.is_a?(SemanticBytecode::OptionGroup) ||
                  node.is_a?(SemanticBytecode::AtomicGroup)
                 node.body
               end
        body = body.parts.first if body.is_a?(SemanticBytecode::Sequence) && body.parts.one?
        operand = reverse_fold_literal_operand(body) if body
        return unless operand
        return operand unless node.is_a?(SemanticBytecode::Group) ||
                              node.is_a?(SemanticBytecode::OptionGroup) ||
                              node.is_a?(SemanticBytecode::AtomicGroup)

        operand.casefold && operand.casefold.length > operand.value.length ? operand : nil
      end

      def reverse_fold_group_sequence_allowed?(parts)
        parts.each_with_index.all? do |part, index|
          next true unless part.is_a?(SemanticBytecode::Group) ||
                           part.is_a?(SemanticBytecode::OptionGroup) ||
                           part.is_a?(SemanticBytecode::AtomicGroup)

          next_operand = parts[index + 1] && reverse_fold_literal_operand(parts[index + 1])
          next_operand&.casefold &&
            next_operand.casefold.length > next_operand.value.length
        end
      end

      def reverse_fold_sequence_compatible?(parts, folded_source)
        wrapped = parts.any? do |part|
          part.is_a?(SemanticBytecode::Group) ||
            part.is_a?(SemanticBytecode::OptionGroup) ||
            part.is_a?(SemanticBytecode::AtomicGroup)
        end
        return reverse_fold_group_sequence_allowed?(parts) if wrapped

        accumulated = +""
        parts.any? do |part|
          operand = reverse_fold_literal_operand(part)
          accumulated << (operand.casefold || operand.value)
          accumulated == folded_source
        end
      end

      def simple_group_literal_node?(node)
        return false if node.is_a?(SemanticBytecode::Group) && node.capture
        return false unless node.is_a?(SemanticBytecode::Group) ||
                            node.is_a?(SemanticBytecode::OptionGroup) ||
                            node.is_a?(SemanticBytecode::AtomicGroup)

        body = node.body
        parts = body.is_a?(SemanticBytecode::Sequence) ? body.parts : [body]
        return false unless parts.all? { |part| part.is_a?(SemanticBytecode::Literal) }

        parts.all? { |part| part.casefold.nil? || part.casefold.length == part.value.length }
      end

      def fold_alternation_operand_node?(node)
        case node
        when SemanticBytecode::Alternation
          node.operand_context
        when SemanticBytecode::Group, SemanticBytecode::OptionGroup,
             SemanticBytecode::AtomicGroup
          fold_alternation_operand_node?(node.body)
        else
          false
        end
      end

      def fold_boundary_operand_fold(node)
        case node
        when SemanticBytecode::Literal
          node.casefold || node.value
        when SemanticBytecode::Group, SemanticBytecode::OptionGroup,
             SemanticBytecode::AtomicGroup
          fold_boundary_operand_fold(node.body)
        when SemanticBytecode::Sequence
          return unless node.parts.all? { |part| fold_boundary_operand_fold(part) }

          node.parts.map { |part| fold_boundary_operand_fold(part) }.join
        end
      end

      def captured_fold_literal_tail_rejected?(node, captures)
        marker = captures[:__captured_expanded_fold] || captures[:__expanded_fold] ||
                 captures[:__quantifier_expanded_fold]
        return false unless marker && !captures[:__fold_alternation_operand]
        return false if captures[:__quantifier_expanded_optional]
        return false if captures[:__match_alternative] && captures[:__expanded_fold]
        return false if captures[:__fold_alternation_context]

        return false unless node.is_a?(SemanticBytecode::Literal)

        fold_boundary_operand_fold(node) != (captures[:__group_expanded_literal_fold] || marker)
      end

      def alternation_branch_operand_value(node)
        node = node.parts.first while node.is_a?(SemanticBytecode::Sequence) && node.parts.length == 1
        node.is_a?(SemanticBytecode::Literal) ? node.value : nil
      end

      def expanded_fold_operand_value(node)
        if node.is_a?(SemanticBytecode::Literal)
          return node.value if node.value.each_char.count > 1

          return node.casefold || node.value
        end
        return if node.is_a?(SemanticBytecode::Group) && node.capture
        return unless node.is_a?(SemanticBytecode::Group) ||
                      node.is_a?(SemanticBytecode::OptionGroup) ||
                      node.is_a?(SemanticBytecode::AtomicGroup)

        body = node.body
        parts = body.is_a?(SemanticBytecode::Sequence) ? body.parts : [body]
        return unless parts.all? { |part| part.is_a?(SemanticBytecode::Literal) }

        parts.map { |part| part.casefold || part.value }.join
      end

      def fold_sequence_expansion_boundaries_valid?(parts, source)
        source_boundaries = [0]
        source.each do |character|
          source_boundaries << source_boundaries.last + character.downcase(:fold).length
        end

        folded_offset = 0
        parts.each_with_index do |part, index|
          if part.is_a?(SemanticBytecode::Literal) &&
             part.casefold && part.casefold.length > part.value.length
            return true if parts.first(index).any? do |prior|
              prior.is_a?(SemanticBytecode::CharacterClass) && prior.casefolds.any?
            end
            return false unless source_boundaries.include?(folded_offset)
          end
          folded_offset += if part.is_a?(SemanticBytecode::Literal)
                             (part.casefold || part.value).length
                           else
                             class_fold_characters(part).length
                           end
        end
        true
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

      def singleton_character_class?(character_class)
        source = character_class.value
        source.each_char.one? && !source.match?(/[\\\[\]:&^]/)
      end

      def class_fold_characters(character_class)
        return character_class.casefolds.flat_map { |_source, value| value.each_char.to_a } unless singleton_character_class?(character_class)

        character = character_class.value
        character.downcase(:fold).each_char.to_a
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

      def fold_repetition_class?(node)
        source = node.value
        return false if source.include?("-") || source.include?("\\") || source.include?(":") ||
                        source.include?("&&")

        characters = source.each_char.to_a
        characters.uniq.one?
      end

      def repeated_class_operand(node)
        return node if node.is_a?(SemanticBytecode::CharacterClass)

        body = if node.is_a?(SemanticBytecode::Group) ||
                  node.is_a?(SemanticBytecode::OptionGroup) ||
                  node.is_a?(SemanticBytecode::AtomicGroup)
                 node.body
               end
        body = body.parts.first if body.is_a?(SemanticBytecode::Sequence) && body.parts.one?
        body if body.is_a?(SemanticBytecode::CharacterClass)
      end

      def repeatable_casefold_operand(node)
        return node if node.is_a?(SemanticBytecode::Literal) ||
                       node.is_a?(SemanticBytecode::CharacterClass)
        return if node.is_a?(SemanticBytecode::Group) && node.capture

        body = if node.is_a?(SemanticBytecode::Group) ||
                  node.is_a?(SemanticBytecode::OptionGroup) ||
                  node.is_a?(SemanticBytecode::AtomicGroup)
                 node.body
               end
        body = body.parts.first if body.is_a?(SemanticBytecode::Sequence) && body.parts.one?
        repeatable_casefold_operand(body) if body
      end

      # MRI changes branch order for an optional folded literal. With no
      # suffix it keeps the consuming branch first. With a different suffix,
      # it keeps only the empty branch, as in `s?a` matching `a` in `ſa`.
      def fold_casefold_optional_order?(node, next_node, characters, cursor, flags)
        wrapper_casefold = option_group_ignorecase?(node)
        if node.is_a?(SemanticBytecode::OptionGroup) && node.body.is_a?(SemanticBytecode::Sequence) &&
           node.body.parts.one?
          node = node.body.parts.first
        end
        return false unless node.is_a?(SemanticBytecode::Quantifier)
        return false unless flags[:ignorecase] || wrapper_casefold || option_group_ignorecase?(node.expression)

        optional = node.minimum.zero? && node.maximum&.positive? && node.mode == :greedy
        lazy_exact = node.lazy_exact && node.minimum.zero? && node.maximum.to_i > 1
        return false unless optional || lazy_exact

        expression = boundary_operand(node.expression)
        if expression.is_a?(SemanticBytecode::CharacterClass) &&
           (!expression.value.each_char.one? || expression.value.match?(/[\\\[\]:&^]/))
          boundary = boundary_operand(next_node)
          return :greedy if expression.value.include?("\\p") &&
                            boundary.is_a?(SemanticBytecode::Anchor)

          return :single_greedy if boundary.is_a?(SemanticBytecode::Anchor) &&
                                   %i[anchor_absolute_start anchor_absolute_end anchor_before_final_newline].include?(boundary.kind)

          return false
        end

        expression_value = if expression.is_a?(SemanticBytecode::Literal)
                             expression.value
                           elsif expression.is_a?(SemanticBytecode::CharacterClass) &&
                                 expression.value.each_char.one? && !expression.value.match?(/[\\\[\]:&^]/)
                             expression.value
                           end
        return false unless expression_value

        source = characters[cursor]
        return false unless source
        if next_node.is_a?(SemanticBytecode::Anchor) &&
           next_node.kind == :anchor_absolute_end &&
           expression.fold_policy&.fetch(:anchor_source, nil) == :fold_group_variant &&
           source != expression.value && !source.match?(/\p{M}/)
          return :zero_only
        end
        if expression.is_a?(SemanticBytecode::Literal) &&
           expression.fold_policy&.fetch(:anchor_source, nil) == :fold_group_variant &&
           source != expression.value && !source.match?(/\p{M}/) &&
           source.downcase(:fold) == expression.value.downcase(:fold) &&
           normal_consuming_operand?(next_node)
          return :zero_only
        end
        if expression.is_a?(SemanticBytecode::CharacterClass) &&
           expression.fold_policy&.fetch(:optional_order, nil) == :consume_source_variant &&
           expression.folded_characters.include?(source)
          return :greedy
        end
        if next_node.is_a?(SemanticBytecode::Anchor) &&
           %i[anchor_absolute_end anchor_before_final_newline].include?(next_node.kind) &&
           simple_fold_source_match?(expression, source)
          return :zero_only
        end
        if next_node.is_a?(SemanticBytecode::Assertion) && next_node.kind == :positive &&
           simple_fold_source_match?(expression, source)
          return :zero_only
        end
        if next_node.is_a?(SemanticBytecode::Literal) &&
           simple_fold_source_match?(expression, source) && next_node.value == source
          return :zero_only
        end
        if next_node && simple_fold_source_match?(expression, source) &&
           normal_consuming_operand?(next_node)
          return :zero_only
        end

        if next_node.is_a?(SemanticBytecode::Literal) &&
           simple_fold_source_match?(expression, source) &&
           next_node.casefold && next_node.casefold.length > next_node.value.length
          return characters[cursor + 1] == next_node.value ? :zero_only : :greedy
        end

        if next_node.is_a?(SemanticBytecode::Literal) && simple_fold_source_match?(expression, source) &&
           Onibi::UnicodeProperties.reverse_source_boundary_variants(next_node.value.downcase(:fold)).include?(next_node.value)
          return :greedy if next_node.value.downcase(:fold) == expression_value.downcase(:fold)

          return :zero_only
        end

        if expression.is_a?(SemanticBytecode::Literal) && expression.value.ascii_only? && next_node &&
           normal_consuming_operand?(next_node) && reverse_simple_fold_source?(expression, source)
          return :zero_only
        end

        return :greedy if next_node && reverse_simple_fold_source?(expression, source)

        expression_special = expression_value.downcase(:fold) != expression_value.downcase
        unless lazy_exact
          return false unless source != expression_value || expression_special
          return false unless source.downcase(:fold) == expression_value.downcase(:fold)
        end
        return :greedy unless next_node

        special_source = source.downcase(:fold) != source.downcase ||
                         (source == expression_value && expression_special)
        return :greedy unless special_source || lazy_exact
        return :greedy if expression_value.downcase(:fold).length > expression_value.length

        boundary_node = boundary_operand(next_node)
        if boundary_node.is_a?(SemanticBytecode::Anchor) &&
           %i[anchor_absolute_start anchor_absolute_end anchor_before_final_newline].include?(boundary_node.kind)
          return :greedy if Onibi::UnicodeProperties.greek?(expression_value)

          return :zero_only unless lazy_exact

          folded_input = characters[cursor, node.maximum].to_a
          return :zero_only if folded_input.any? { |character| character.downcase(:fold) != character.downcase }

        end
        return :greedy unless next_node.is_a?(SemanticBytecode::Literal) ||
                              next_node.is_a?(SemanticBytecode::CharacterClass) ||
                              next_node.is_a?(SemanticBytecode::Quantifier)
        return :greedy if next_node.is_a?(SemanticBytecode::Quantifier) && next_node.minimum.zero?
        if next_node.is_a?(SemanticBytecode::Quantifier) && next_node.minimum.positive? &&
           next_node.expression.is_a?(SemanticBytecode::Assertion)
          return :greedy
        end
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
        return :greedy if next_node.is_a?(SemanticBytecode::CharacterClass)
        if next_node.is_a?(SemanticBytecode::Quantifier) &&
           next_node.expression.is_a?(SemanticBytecode::CharacterClass) &&
           next_node.maximum && next_node.maximum > next_node.minimum &&
           Onibi::ClassPredicates.matches?(next_node.expression.value,
                                           expression_value.downcase(:fold),
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

      # A reverse-fold optional followed by the same fold operand cannot
      # fall back to the empty branch when a suffix remains. This is encoded
      # by the compiler's reverse source table, not by a character special case.
      def reverse_fold_optional_barrier?(node, next_node, suffix_node, characters, cursor, flags)
        if node.is_a?(SemanticBytecode::OptionGroup) && node.body.is_a?(SemanticBytecode::Sequence)
          inner = node.body.parts
          return reverse_fold_optional_barrier?(inner.first, next_node, suffix_node, characters, cursor,
                                                flags.merge(ignorecase: node.ignorecase)) if inner.one?

          return reverse_fold_optional_barrier?(inner[0], inner[1], suffix_node || next_node, characters, cursor,
                                                flags.merge(ignorecase: node.ignorecase))
        end
        return false unless flags[:ignorecase] || option_group_ignorecase?(node)
        return false unless node.is_a?(SemanticBytecode::Quantifier)
        return false unless node.minimum.zero? && node.maximum == 1 && node.mode == :greedy
        return false unless next_node.is_a?(SemanticBytecode::Literal)

        expression = boundary_operand(node.expression)
        return false unless expression.is_a?(SemanticBytecode::Literal)
        return false unless expression.value.each_char.one? && next_node.value.each_char.one?

        source = characters[cursor]
        if expression.value.encoding == Encoding::UTF_8 && !expression.value.ascii_only? &&
           expression.value.downcase(:fold).each_char.one? &&
           Onibi::UnicodeProperties.reverse_casefold_variants(expression.value.downcase(:fold)).empty? &&
           source == expression.value &&
           next_node.value.downcase(:fold) != expression.value.downcase(:fold)
          return true
        end

        return false unless suffix_node
        return false unless expression.value.downcase(:fold) == next_node.value.downcase(:fold)

        return false if suffix_node.is_a?(SemanticBytecode::Anchor) &&
                        expression.fold_policy&.fetch(:sequence_source, nil) != :allow_repeated_variant

        variants = Onibi::UnicodeProperties.reverse_source_boundary_variants(
          expression.value.downcase(:fold)
        )
        source && variants.include?(source)
      end

      def lookahead_variant_barrier?(node, characters, cursor, flags, anchored: false)
        if node.parts[0].is_a?(SemanticBytecode::OptionGroup) &&
           node.parts[1].is_a?(SemanticBytecode::Anchor) && strict_end_anchor?(node.parts[1])
          option = node.parts[0]
          body = option.body
          return false unless option.ignorecase && body.is_a?(SemanticBytecode::Sequence)

          nested = SemanticBytecode::Sequence.new(body.parts)
          return lookahead_variant_barrier?(nested, characters, cursor, flags.merge(ignorecase: true), anchored: true)
        end
        return false unless flags[:ignorecase]
        return false unless anchored

        assertion = node.parts[0]
        operand = boundary_operand(node.parts[1])
        return false unless assertion.is_a?(SemanticBytecode::Assertion) && assertion.kind == :positive

        body = boundary_operand(assertion.body)
        return false unless body.is_a?(SemanticBytecode::Literal)
        return false unless operand.is_a?(SemanticBytecode::Literal)
        return false unless body.value.downcase(:fold) == operand.value.downcase(:fold)

        source = characters[cursor]
        body.fold_policy&.fetch(:anchor_source, nil) == :fold_group_variant &&
          source && source != body.value && !source.match?(/\p{M}/) &&
          source.downcase(:fold) == body.value.downcase(:fold)
      end

      def expanded_quantifier_anchor_barrier?(node, characters, cursor, flags)
        quantifier = node.parts[0]
        anchor = node.parts[1]
        return false unless anchor.is_a?(SemanticBytecode::Anchor) && strict_end_anchor?(anchor)

        if quantifier.is_a?(SemanticBytecode::OptionGroup) && quantifier.body.is_a?(SemanticBytecode::Sequence)
          return false unless quantifier.ignorecase

          quantifier = quantifier.body.parts.first
        else
          return false unless flags[:ignorecase]
        end
        return false unless quantifier.is_a?(SemanticBytecode::Quantifier)
        return false unless quantifier.minimum.positive? && quantifier.maximum.nil?

        literal = boundary_operand(quantifier.expression)
        return false unless literal.is_a?(SemanticBytecode::Literal) && literal.casefold

        literal.casefold.length > literal.value.length &&
          literal.casefold.each_char.uniq.length > 1 && characters.length - cursor == 1
      end

      def same_fold_literal?(node, expression)
        literal = node
        literal = node.expression if node.is_a?(SemanticBytecode::Quantifier)
        literal = node if node.is_a?(SemanticBytecode::CharacterClass) && node.casefolds.empty?
        (literal.is_a?(SemanticBytecode::Literal) || literal.is_a?(SemanticBytecode::CharacterClass)) &&
          literal.value.downcase(:fold) == expression.value.downcase(:fold)
      end

      def simple_fold_source_match?(node, source)
        @fold_policy.classify(node, source) == :simple_source
      end

      def simple_fold_boundary_for(node, source)
        @fold_policy.boundary(node, source)
      end

      def reverse_simple_fold_source?(node, source)
        @fold_policy.classify(node, source) == :reverse_source
      end

      def normal_consuming_operand?(node)
        operand = boundary_operand(node)
        if operand.is_a?(SemanticBytecode::Literal)
          return false if Onibi::UnicodeProperties.reverse_source_boundary_variants(
            operand.value.downcase(:fold)
          ).include?(operand.value)

          return (operand.casefold || operand.value).length == operand.value.length
        end
        return false if operand.is_a?(SemanticBytecode::CharacterClass)

        false
      end

      def multi_fold_literal_boundary?(node, next_node, characters, cursor, flags)
        return false if flags[:fold_alternation]

        original_node = node
        fold_enabled = flags[:ignorecase] || option_group_ignorecase?(node) ||
                       (node.is_a?(SemanticBytecode::Quantifier) && option_group_ignorecase?(node.expression))

        wrapped_previous = node.is_a?(SemanticBytecode::Group) ||
                           node.is_a?(SemanticBytecode::OptionGroup) ||
                           node.is_a?(SemanticBytecode::AtomicGroup)
        wrapped_next = next_node.is_a?(SemanticBytecode::Group) ||
                       next_node.is_a?(SemanticBytecode::OptionGroup) ||
                       next_node.is_a?(SemanticBytecode::AtomicGroup)
        node = boundary_operand(node)
        next_node = boundary_operand(next_node)
        if node.is_a?(SemanticBytecode::Group)
          body = node.body
          node = body.parts.first if body.is_a?(SemanticBytecode::Sequence) && body.parts.length == 1
        end
        node = node.parts.first if node.is_a?(SemanticBytecode::Sequence) && node.parts.length == 1
        if fold_enabled && node.is_a?(SemanticBytecode::CharacterClass) &&
           node.casefolds.length == 1 && next_node.is_a?(SemanticBytecode::Literal)
          source = characters[cursor]
          fold = node.casefolds.first[1]
          boundary = node.fold_boundaries[node.value]
          next_value = next_node.value
          return true if source == node.value && boundary &&
                         fold.start_with?(next_value) &&
                         characters[cursor + 1]&.downcase(:fold) == next_value

          return false
        end
        if fold_enabled && node.is_a?(SemanticBytecode::CharacterClass) &&
           simple_fold_source_match?(node, characters[cursor]) && next_node.is_a?(SemanticBytecode::Literal) &&
           !(next_node.casefold && next_node.casefold.length > next_node.value.length) &&
           !node.value.include?("\\")
          return true
        end
        return false unless fold_enabled && node.is_a?(SemanticBytecode::Literal)

        source = characters[cursor]
        return false unless source
        return false if node.value.ascii_only? && source.ascii_only?
        return false if next_node.is_a?(SemanticBytecode::CharacterClass)

        if simple_fold_source_match?(node, source) && next_node.is_a?(SemanticBytecode::Literal) &&
           !(next_node.casefold && next_node.casefold.length > next_node.value.length)
          return true
        end

        if next_node.is_a?(SemanticBytecode::Anchor) &&
           %i[anchor_absolute_start anchor_absolute_end anchor_before_final_newline].include?(next_node.kind) && source && source != node.value &&
           source.downcase(:fold) == node.value.downcase(:fold)
          return false if reverse_fold_source_literal?(node.value)

          return true
        end
        return false unless node.casefold && node.casefold.length > node.value.length

        return false if wrapped_previous && next_node.is_a?(SemanticBytecode::Literal) &&
                        next_node.casefold&.length.to_i > next_node.value.length

        return false unless node.fold_boundary_sensitive
        return false unless source == node.value

        if original_node.is_a?(SemanticBytecode::Quantifier) && original_node.minimum.zero?
          operand = boundary_operand(original_node.expression)
          return false if operand.is_a?(SemanticBytecode::Literal) &&
                          operand.fold_boundary&.fetch(:kind, nil) == :expanded_tail
        end

        next_source = characters[cursor + 1]
        if next_source && next_source.downcase(:fold).length > 1 &&
           next_source.downcase(:fold) == next_node_value(next_node)
          return false
        end

        next_value = next_node_value(next_node)
        if next_node.is_a?(SemanticBytecode::Literal) && next_value &&
           node.casefold.start_with?(next_value) &&
           node.fold_boundary.nil? &&
           next_source && next_source.downcase(:fold) == next_value
          return false
        end
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
        return false if wrapped_next && next_node.is_a?(SemanticBytecode::Literal) &&
                        next_node.casefold&.length.to_i > next_node.value.length
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
          elsif node.is_a?(SemanticBytecode::OptionGroup) || node.is_a?(SemanticBytecode::AtomicGroup)
            node = node.body
          elsif node.is_a?(SemanticBytecode::Sequence) && node.parts.length == 1
            node = node.parts.first
          else
            return node
          end
        end
      end

      def fold_boundary_lookahead_relaxed?(previous_node, node, next_node, characters, cursor)
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

      def simple_fold_lookahead_boundary?(node, next_node, characters, cursor, flags)
        fold_enabled = flags[:ignorecase] || option_group_ignorecase?(node)
        node = boundary_operand(node)
        return false unless fold_enabled
        return false unless next_node.is_a?(SemanticBytecode::Assertion) && next_node.kind == :positive
        return false unless node.is_a?(SemanticBytecode::Literal)

        simple_fold_source_match?(node, characters[cursor])
      end

      def simple_fold_sequence_boundary?(node, next_node, characters, cursor, flags)
        return false unless flags[:ignorecase] || option_group_ignorecase?(node)
        return false unless next_node.is_a?(SemanticBytecode::Literal) ||
                            next_node.is_a?(SemanticBytecode::Anchor)

        operand = boundary_operand(node)
        return false unless operand.is_a?(SemanticBytecode::Sequence) && operand.parts.length > 1
        return false unless operand.parts.all? { |part| part.is_a?(SemanticBytecode::Literal) }
        return false if !next_node.is_a?(SemanticBytecode::Anchor) && operand.parts.all? do |part|
          part.fold_policy&.fetch(:sequence_source, nil) == :allow_repeated_variant
        end

        source = characters[cursor, operand.parts.length]
        return false unless source.length == operand.parts.length

        return false unless operand.parts.zip(source).all? do |part, character|
          character.downcase(:fold) == part.value.downcase(:fold)
        end

        if next_node.is_a?(SemanticBytecode::Anchor) &&
           %i[anchor_absolute_end anchor_before_final_newline].include?(next_node.kind) &&
           operand.parts.first.value.downcase(:fold) == "k" && source.first == "K"
          return true
        end

        source.uniq.length == 1 && operand.parts.any? do |part|
          Onibi::UnicodeProperties.reverse_source_boundary_variants(
            part.value.downcase(:fold)
          ).include?(source.first)
        end
      end

      def alternate_anchor_relaxed?(node, next_node, characters, cursor, flags)
        return false unless flags[:ignorecase] && node.is_a?(SemanticBytecode::Literal)
        return false unless end_anchor?(next_node)
        return false unless %i[anchor_absolute_start anchor_absolute_end anchor_before_final_newline].include?(next_node.kind)

        source = characters[cursor]
        return false if source && Onibi::UnicodeProperties.reverse_casefold_variants(node.value).include?(source)

        source && source != node.value && source.downcase(:fold) == node.value.downcase(:fold)
      end

      def alternate_fold_quantifier_anchor_boundary?(node, next_node, characters, cursor, flags)
        return false unless node.is_a?(SemanticBytecode::Quantifier)
        return false unless node.minimum == node.maximum
        return false unless end_anchor?(next_node)

        expression = unwrap_literal_operand(node.expression)
        fold_enabled = flags[:ignorecase] || option_group_ignorecase?(node.expression)
        return false unless fold_enabled

        value = if expression.is_a?(SemanticBytecode::Literal)
                  expression.value
                elsif expression.is_a?(SemanticBytecode::CharacterClass) &&
                      expression.value.each_char.one? && !expression.value.match?(/[\\\[\]:&^]/)
                  expression.value
                end
        return false unless value

        if reverse_fold_source_literal?(value)
          maximum = [node.maximum, characters.length - cursor].min
          return false if next_node.kind == :anchor_end &&
                          characters[cursor, maximum].to_a.all? { |character| character == value }
          return false if characters[cursor, maximum].to_a.all?(&:ascii_only?)
        end
        return false if Onibi::UnicodeProperties.greek?(value)

        maximum = [node.maximum, characters.length - cursor].min
        folded_value = value.downcase(:fold)
        return true if folded_value.length == 1 && folded_value != value.downcase &&
                       characters[cursor, maximum].to_a.all? { |character| character.downcase(:fold) == folded_value }

        characters[cursor, maximum].to_a.any? do |character|
          character != value && character.downcase(:fold) == value.downcase(:fold)
        end
      end

      def distinct_expanded_anchor_boundary?(node, next_node, characters, cursor, flags)
        return false unless node.is_a?(SemanticBytecode::Quantifier)
        return false unless strict_end_anchor?(next_node)

        expression = unwrap_literal_operand(node.expression)
        return false unless flags[:ignorecase] || option_group_ignorecase?(node.expression)

        if expression.is_a?(SemanticBytecode::CharacterClass)
          value = characters[cursor]
          folded = class_expanded_fold(expression, value)
          return false unless folded
        elsif expression.is_a?(SemanticBytecode::Literal)
          value = expression.value
          folded = value.downcase(:fold)
        else
          return false
        end
        return false unless folded.length > value.length && folded.each_char.uniq.length > 1

        boundary = if expression.is_a?(SemanticBytecode::CharacterClass)
                     expression.fold_boundaries[value]
                   else
                     expression.fold_boundary
                   end
        return false unless boundary

        source = characters[cursor]
        source && source.downcase(:fold).length > source.length &&
          source.downcase(:fold) == folded
      end

      def expanded_fold_prefix_boundary?(node, next_node, characters, cursor, flags)
        next_body = if next_node.is_a?(SemanticBytecode::Assertion) &&
                       next_node.kind == :positive
                      next_node.body
                    else
                      next_node
                    end
        next_operands = boundary_literal_operands(next_body)
        return false if next_operands.empty?

        expression = boundary_operand(node)
        grouped_fold = node.is_a?(SemanticBytecode::Group) &&
                       capture_body_has_expanding_literal?(node.body)
        return false unless flags[:ignorecase] || option_group_ignorecase?(node) || grouped_fold

        source = characters[cursor]
        fold = if expression.is_a?(SemanticBytecode::CharacterClass)
                 return false unless expression.casefolds.length == 1

                 return false unless source == expression.value

                 expression.casefolds.first[1]
               elsif expression.is_a?(SemanticBytecode::Literal)
                 return false unless source == expression.value

                 expression.casefold || expression.value.downcase(:fold)
               end
        return false unless fold

        boundary = if expression.is_a?(SemanticBytecode::CharacterClass)
                     expression.fold_boundaries[source]
                   else
                     expression.fold_boundary
                   end
        return false unless boundary

        tail = boundary[:tail]
        return false if next_node.is_a?(SemanticBytecode::Assertion) && next_node.kind == :positive && characters[cursor + 2] && characters[cursor + 2] != tail

        return true if next_operands.any? { |operand| operand.value == tail } &&
                       characters[cursor + 1] == tail

        if boundary_operand(next_body).is_a?(SemanticBytecode::Alternation)
          next_character = characters[cursor + 1]
          return true if next_character == tail &&
                         next_operands.any? { |operand| operand.value == tail }

          folded_remainder = fold.each_char.to_a.drop(next_character.to_s.each_char.count)
          input_remainder = characters[(cursor + 2), folded_remainder.length]
          return false if next_character &&
                          fold.start_with?(next_character) &&
                          input_remainder == folded_remainder

          return false if next_character && fold.start_with?(next_character) &&
                          characters.length > cursor + 2

          return true if next_character && fold.start_with?(next_character)
        end

        next_operands.any? do |next_operand|
          next_value = next_operand.value
          next false if next_node.is_a?(SemanticBytecode::Assertion) && next_operand.fold_prefix_boundary != :non_split_prefix

          fold.start_with?(next_value) &&
            characters[cursor + 1]&.downcase(:fold) == next_value
        end
      end

      def positive_lookahead_extra_character_relaxed?(node, next_node, characters, cursor)
        return false unless next_node.is_a?(SemanticBytecode::Assertion) &&
                            next_node.kind == :positive

        boundary = fold_boundary_for_node(node)
        return false unless boundary

        extra = characters[cursor + 2]
        extra && extra != boundary[:tail]
      end

      def reverse_fold_quantifier_anchor_source_width?(node, next_node, characters, cursor, flags)
        return false unless flags[:ignorecase] && node.is_a?(SemanticBytecode::Quantifier)
        return false unless node.maximum &&
                            (node.maximum > node.minimum || (node.minimum.zero? && node.maximum == 1))

        expression = node.expression
        return false unless expression.is_a?(SemanticBytecode::Literal)
        return false unless strict_end_anchor?(next_node)

        source = characters[cursor]
        return false unless source

        if reverse_fold_source_literal?(expression.value)
          return true if source == expression.value

          return characters.drop(cursor + node.minimum).include?(expression.value)
        end

        variants = Onibi::UnicodeProperties.reverse_casefold_variants(expression.value)
        variants.include?(source) || characters.drop(cursor + 1).any? { |character| variants.include?(character) }
      end

      def reverse_fold_quantifier_anchor_reject?(node, next_node, characters, cursor, flags)
        return false unless flags[:ignorecase] && node.is_a?(SemanticBytecode::Quantifier)
        return false unless node.minimum.positive? && node.maximum && node.maximum > node.minimum

        expression = node.expression
        return false unless expression.is_a?(SemanticBytecode::Literal)
        return false unless strict_end_anchor?(next_node)

        source = characters[cursor]
        return false if source && Onibi::UnicodeProperties.greek?(source)
        return true if source == expression.value &&
                       reverse_fold_source_literal?(expression.value) &&
                       source.downcase != source

        source && source != expression.value &&
          source.downcase == expression.value.downcase && source.downcase != source
      end

      def split_reverse_fold_quantifier_anchor_boundary?(previous_node, node, next_node,
                                                         characters, cursor, flags)
        return false unless flags[:ignorecase] && previous_node.is_a?(SemanticBytecode::Literal)
        return false unless node.is_a?(SemanticBytecode::Quantifier)
        return false unless node.maximum && node.maximum > node.minimum
        return false unless node.expression.is_a?(SemanticBytecode::Literal)
        return false unless strict_end_anchor?(next_node)
        return false unless previous_node.value == node.expression.value

        source = characters[cursor]
        return false if characters[cursor - 1] == previous_node.value

        source && Onibi::UnicodeProperties.reverse_casefold_variants(node.expression.value).include?(source)
      end

      def alternate_fold_literal_run_anchor_boundary?(node, next_node, characters, cursor, flags)
        return false unless flags[:ignorecase] && node.is_a?(SemanticBytecode::Literal)
        return false unless next_node.is_a?(SemanticBytecode::Anchor)
        return false unless node.value.length > 1 && node.value.each_char.all? { |character| character == node.value[0] }
        return false if next_node.kind == :anchor_end

        source = characters[cursor]
        return false unless source && source != node.value[0]
        return false if Onibi::UnicodeProperties.greek?(source)

        source.downcase(:fold).length == 1 &&
          source.downcase(:fold) == node.value[0].downcase(:fold)
      end

      def posix_anchor_source_width?(node, next_node, characters, cursor)
        operand = node.is_a?(SemanticBytecode::Quantifier) ? boundary_operand(node.expression) : boundary_operand(node)
        operand = boundary_operand(operand)
        return false unless operand.is_a?(SemanticBytecode::CharacterClass)
        return false unless operand.value.include?(":")
        return false if node.is_a?(SemanticBytecode::Quantifier) && node.maximum.nil?

        source = characters[cursor]
        return false unless source

        return false unless next_node.is_a?(SemanticBytecode::Anchor)

        source.ascii_only? ? :source_only : :expanded_greedy
      end

      def posix_expanded_optional_anchor?(node, next_node, characters, cursor)
        return false unless node.is_a?(SemanticBytecode::Quantifier)
        return false unless node.minimum.zero? && node.maximum == 1
        return false unless node.expression.is_a?(SemanticBytecode::CharacterClass)
        return false unless node.expression.value.include?(":")
        return false unless end_anchor?(next_node)

        !characters[cursor].nil? && !characters[cursor].ascii_only?
      end

      def reverse_fold_literal_anchor_boundary?(node, next_node, characters, cursor, flags)
        return false unless (flags[:ignorecase] || option_group_ignorecase?(node)) && strict_end_anchor?(next_node)

        operand = node.is_a?(SemanticBytecode::Quantifier) ? boundary_operand(node.expression) : boundary_operand(node)
        return false if node.is_a?(SemanticBytecode::Quantifier) && node.minimum != node.maximum
        return false unless operand.is_a?(SemanticBytecode::Literal)
        return false unless operand.value.each_char.one?

        policy = operand.fold_policy || {}
        return false unless reverse_fold_source_literal?(operand.value) ||
                            policy[:anchor_source] == :fold_group_variant

        source = characters[cursor]
        return false unless source

        return true if policy[:anchor_source] == :fold_group_variant &&
                       source != operand.value &&
                       !source.match?(/\p{M}/) &&
                       Onibi::UnicodeProperties.reverse_casefold_variants(operand.value.downcase(:fold)).include?(source) &&
                       source.downcase(:fold) == operand.value.downcase(:fold)
        return false if policy[:anchor_source] == :fold_group_variant && source == operand.value

        source == operand.value
      end

      def reverse_fold_optional_anchor_boundary?(node, next_node, characters, cursor, flags)
        return false unless (flags[:ignorecase] || option_group_ignorecase?(node)) && strict_end_anchor?(next_node)

        quantifier = if node.is_a?(SemanticBytecode::Quantifier)
                       node
                     elsif node.is_a?(SemanticBytecode::OptionGroup) && node.body.is_a?(SemanticBytecode::Sequence) &&
                           node.body.parts.one? && node.body.parts.first.is_a?(SemanticBytecode::Quantifier)
                       node.body.parts.first
                     end
        return false unless quantifier
        return false unless quantifier.minimum.zero? && quantifier.maximum == 1
        return false unless quantifier.expression.is_a?(SemanticBytecode::Literal)

        policy = quantifier.expression.fold_policy || {}
        return false unless reverse_fold_source_literal?(quantifier.expression.value) ||
                            policy[:anchor_source] == :fold_group_variant

        source = characters[cursor]
        return true if source == quantifier.expression.value && policy[:anchor_source] == :fold_group_variant

        source && !source.match?(/\p{M}/) &&
          Onibi::UnicodeProperties.reverse_casefold_variants(quantifier.expression.value.downcase(:fold)).include?(source)
      end

      def end_anchor?(node)
        node.is_a?(SemanticBytecode::Anchor) &&
          %i[anchor_absolute_end anchor_before_final_newline anchor_end].include?(node.kind)
      end

      def strict_end_anchor?(node)
        node.is_a?(SemanticBytecode::Anchor) &&
          %i[anchor_absolute_end anchor_before_final_newline].include?(node.kind)
      end

      def posix_alternation_anchor_source_width?(node, next_node, characters, cursor)
        node = boundary_operand(node)
        return false unless node.is_a?(SemanticBytecode::Alternation)
        return false unless end_anchor?(next_node)
        return false unless node.branches.any? do |branch|
          operand = boundary_operand(branch)
          operand.is_a?(SemanticBytecode::Property) ||
          operand.is_a?(SemanticBytecode::Any) ||
          (operand.is_a?(SemanticBytecode::CharacterClass) && operand.value.include?(":"))
        end
        return false if node.branches.any? do |branch|
          operand = boundary_operand(branch)
          operand.is_a?(SemanticBytecode::Literal) &&
          (operand.casefold&.length.to_i > operand.value.length ||
           reverse_fold_source_literal?(operand.value))
        end

        characters[cursor]&.ascii_only?
      end

      def fold_property_alternation_anchor_expansion?(node, next_node, characters, cursor)
        node = boundary_operand(node)
        return false unless node.is_a?(SemanticBytecode::Alternation)
        return false unless end_anchor?(next_node)
        return false unless node.branches.any? do |branch|
          boundary_operand(branch).is_a?(SemanticBytecode::Property)
        end

        characters[cursor]&.ascii_only?
      end

      def reverse_fold_source_literal?(value)
        return false if value.ascii_only?
        return false unless value.downcase(:fold).length == value.length

        Onibi::UnicodeProperties::REVERSE_SIMPLE_CASEFOLDS.any? do |_base, variants|
          variants.include?(value)
        end
      end

      def alternate_fold_alternation_anchor_boundary?(node, next_node, characters, cursor, flags)
        return false unless flags[:ignorecase]

        node = boundary_operand(node)
        return false unless node.is_a?(SemanticBytecode::Alternation)
        return false unless strict_end_anchor?(next_node)

        source = characters[cursor]
        return false unless source
        return false if source.ascii_only?
        return false if node.branches.any? do |branch|
          literal = boundary_operand(branch)
          literal.is_a?(SemanticBytecode::Literal) &&
          literal.casefold&.length.to_i > literal.value.length
        end
        return false if node.branches.any? do |branch|
          operand = boundary_operand(branch)
          operand.is_a?(SemanticBytecode::Property) || operand.is_a?(SemanticBytecode::Any) ||
          (operand.is_a?(SemanticBytecode::Escape) && operand.kind == :word) ||
          (operand.is_a?(SemanticBytecode::CharacterClass) && operand.value.include?(":"))
        end

        node.branches.any? do |branch|
          literal = boundary_operand(branch)
          next false unless literal.is_a?(SemanticBytecode::Literal)

          (reverse_fold_source_literal?(literal.value) && literal.value == source) ||
            Onibi::UnicodeProperties.reverse_casefold_variants(literal.value).include?(source)
        end
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

      def multi_fold_quantifier_boundary?(node, next_node, characters, cursor, flags)
        return false if flags[:fold_alternation]
        return false unless node.is_a?(SemanticBytecode::Quantifier)
        return false unless node.minimum.positive?
        return false if node.maximum.nil?

        expression = boundary_operand(node.expression)
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
        return false unless expression.is_a?(SemanticBytecode::Literal)
        return false if next_node.is_a?(SemanticBytecode::Quantifier) && next_node.minimum.zero?

        if simple_fold_source_match?(expression, characters[cursor]) &&
           next_node.is_a?(SemanticBytecode::Literal)
          return expression.value.downcase(:fold) == "k" &&
                 (!next_node.value.ascii_only? || next_node.casefold&.length.to_i > next_node.value.length)
        end

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

        multi_fold_literal_boundary?(expression, next_node, characters, cursor, flags)
      end

      def backreference_anchor_boundary?(node, next_node, captures, flags)
        return false unless flags[:ignorecase]
        return false unless node.is_a?(SemanticBytecode::Backreference)
        return false unless next_node.is_a?(SemanticBytecode::Anchor)
        return false unless %i[anchor_absolute_start anchor_absolute_end anchor_before_final_newline].include?(next_node.kind)

        span = captures[node.identifier]
        return false unless span
        return true if Array(captures[:__reverse_literal_capture_numbers]).include?(node.identifier)
        return false if Array(captures[:__class_capture_numbers]).include?(node.identifier)

        value = @characters[span[0]...span[1]].join
        folded = value.downcase(:fold)
        return false if value.each_char.all? { |character| Onibi::UnicodeProperties.greek?(character) }

        folded.length == value.length && folded != value.downcase
      end

      def capture_body_has_class?(node)
        case node
        when SemanticBytecode::CharacterClass, SemanticBytecode::Property,
             SemanticBytecode::Any
          true
        when SemanticBytecode::Escape
          node.kind == :word
        when SemanticBytecode::Sequence
          node.parts.any? { |part| capture_body_has_class?(part) } ||
            node.parts.length > 1 && node.parts.any? do |part|
              part.is_a?(SemanticBytecode::Quantifier) &&
                part.minimum.zero? && part.maximum == 1
            end
        when SemanticBytecode::Alternation
          node.branches.any? { |branch| capture_body_has_class?(branch) } ||
            node.branches.any? { |branch| capture_body_has_expanding_literal?(branch) }
        when SemanticBytecode::Group, SemanticBytecode::OptionGroup,
             SemanticBytecode::AtomicGroup
          capture_body_has_class?(node.body)
        when SemanticBytecode::Quantifier
          node.maximum.nil? || (node.maximum > node.minimum && node.maximum > 1) ||
            capture_body_has_class?(node.expression)
        else
          false
        end
      end

      def capture_body_has_expanding_literal?(node)
        case node
        when SemanticBytecode::Literal
          node.casefold && node.casefold.length > node.value.length
        when SemanticBytecode::Sequence
          node.parts.any? { |part| capture_body_has_expanding_literal?(part) }
        when SemanticBytecode::Alternation
          node.branches.any? { |branch| capture_body_has_expanding_literal?(branch) }
        when SemanticBytecode::Group, SemanticBytecode::OptionGroup,
             SemanticBytecode::AtomicGroup
          capture_body_has_expanding_literal?(node.body)
        when SemanticBytecode::Quantifier
          capture_body_has_expanding_literal?(node.expression)
        else
          false
        end
      end

      def fold_boundary_for_node(node)
        case node
        when SemanticBytecode::Literal
          node.fold_boundary
        when SemanticBytecode::CharacterClass
          node.fold_boundaries.values.compact.first
        when SemanticBytecode::Sequence
          node.parts.lazy.map { |part| fold_boundary_for_node(part) }.find(&:itself)
        when SemanticBytecode::Group, SemanticBytecode::OptionGroup,
             SemanticBytecode::AtomicGroup
          fold_boundary_for_node(node.body)
        when SemanticBytecode::Quantifier
          fold_boundary_for_node(node.expression)
        end
      end

      def reverse_literal_capture_origin?(body, characters, cursor, length)
        literal = if body.is_a?(SemanticBytecode::Sequence) && body.parts.length == 1
                    body.parts.first
                  else
                    body
                  end
        return false unless literal.is_a?(SemanticBytecode::Literal)
        return false unless reverse_fold_source_literal?(literal.value)

        captured = characters[cursor, length]&.join
        captured && captured != literal.value
      end

      def fold_boundary_relaxed?(previous_node, node, consumed)
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

      def folded_atoms_match?(atoms, folded, flags, allow_fold_tail: false, split_class: true)
        return folded.empty? || allow_fold_tail if atoms.empty?

        atom = atoms.first
        if atom.is_a?(SemanticBytecode::Literal)
          value = atom.value.downcase(:fold)
          return false unless folded.start_with?(value)

          return folded_atoms_match?(atoms.drop(1), folded[value.length..], flags,
                                     allow_fold_tail: allow_fold_tail, split_class: split_class)
        end

        character = folded.each_char.first
        return false unless character

        if atom.is_a?(SemanticBytecode::CharacterClass) && atom.split_casefold && !split_class
          value = class_fold_characters(atom).join
          return false unless folded.start_with?(value)

          return folded_atoms_match?(atoms.drop(1), folded[value.length..], flags,
                                     allow_fold_tail: allow_fold_tail, split_class: split_class)
        end

        matched = if atom.is_a?(SemanticBytecode::CharacterClass)
                    Onibi::ClassPredicates.matches?(atom.value, character,
                                                    ignorecase: true,
                                                    encoding: flags[:encoding]) ||
                      Array(atom.casefolds).any? { |_source, value| value.start_with?(character) }
                  else
                    false
                  end
        matched && folded_atoms_match?(atoms.drop(1), folded[character.length..], flags,
                                       allow_fold_tail: allow_fold_tail, split_class: split_class)
      end

      def quantifier_results(quantifier, characters, cursor, captures, flags = {})
        # Quantifier transition:
        #   input  = <quantifier, cursor, captures, flags>
        #   output = ordered [[total_length, repeat_state], ...]
        # Each repeat starts from cursor + total_length. A zero-width repeat
        # still changes only its local repeat state and cannot move the cursor.
        if captures[:__end_zero_width] && characters.join.bytesize > 1 && flags[:multiline] &&
           quantifier.mode != :lazy &&
           quantifier.minimum.zero? && quantifier.maximum.nil? &&
           quantifier.expression.is_a?(SemanticBytecode::Any) &&
           quantifier.expression.value == "."
          return []
        end

        if quantifier.minimum == 1 && quantifier.maximum == 1 &&
           quantifier.expression.is_a?(SemanticBytecode::OptionGroup)
          return tree_results(quantifier.expression, characters, cursor, captures, flags)
        end

        if flags[:ignorecase] && flags[:posix_anchor_expansion] && quantifier.maximum == 1 &&
           quantifier.expression.is_a?(SemanticBytecode::CharacterClass) &&
           quantifier.expression.value.include?(":")
          expanded = tree_results(quantifier.expression, characters, cursor, captures, flags)
          expanded = expanded.select { |length, _state| length > 1 }
          return expanded + [[0, captures]] if expanded.any? && quantifier.minimum.zero?
          return expanded if expanded.any?
        end

        if flags[:ignorecase] && quantifier.lazy_exact && quantifier.maximum.to_i.positive? &&
           (quantifier.expression.is_a?(SemanticBytecode::Literal) ||
            quantifier.expression.is_a?(SemanticBytecode::CharacterClass))
          # A lazy exact repeat has two VM candidates: the complete repeat and
          # its zero-repeat fallback. Compile the complete repeat as one
          # sequence so multi-character Unicode folds, such as ß -> ss, keep
          # their source boundary.
          repeated = SemanticBytecode::Sequence.new(
            Array.new(quantifier.maximum, quantifier.expression)
          )
          repetition_flags = if quantifier.expression.is_a?(SemanticBytecode::CharacterClass)
                               flags.merge(casefold_repetition: true)
                             else
                               flags
                             end
          exact = tree_results(repeated, characters, cursor, captures, repetition_flags)
          return exact + [[0, captures]] unless exact.any? { |length, _state| length.zero? }

          return exact
        end

        if flags[:ignorecase] && quantifier.minimum == quantifier.maximum &&
           quantifier.minimum > 1 &&
           repeatable_casefold_operand(quantifier.expression)
          # A fixed repetition is one logical literal sequence. Matching each
          # operand alone would lose reverse folds such as `ſ{2}` versus `ß`.
          repeated = SemanticBytecode::Sequence.new(
            Array.new(quantifier.minimum, quantifier.expression)
          )
          repetition_flags = if repeatable_casefold_operand(quantifier.expression).is_a?(SemanticBytecode::CharacterClass)
                               flags.merge(casefold_repetition: true)
                             else
                               flags
                             end
          return tree_results(repeated, characters, cursor, captures, repetition_flags)
        end

        return possessive_quantifier_results(quantifier, characters, cursor, captures, flags) if quantifier.mode == :possessive

        results = ordered_quantifier_results(quantifier, characters, cursor, captures, flags)
        return results unless flags[:negated_class_casefold_barrier]

        maximum = results.map(&:first).max
        results.select { |length, _state| length == maximum }
      end

      def negated_class_casefold_barrier?(node, next_node, flags)
        return false unless node.is_a?(SemanticBytecode::Quantifier)
        return false if node.mode == :lazy || !node.expression.is_a?(SemanticBytecode::CharacterClass)
        return false unless node.expression.value.start_with?("^")
        return false unless next_node.is_a?(SemanticBytecode::OptionGroup) && next_node.ignorecase

        body = next_node.body
        body = body.parts.one? && body.parts.first if body.is_a?(SemanticBytecode::Sequence)
        return false unless body.is_a?(SemanticBytecode::Literal)

        folded = body.casefold || body.value.downcase(:fold)
        folded.each_char.any? do |character|
          !Onibi::ClassPredicates.matches?(node.expression.value, character,
                                           encoding: flags[:encoding])
        end
      end

      def ordered_quantifier_results(quantifier, characters, cursor, captures, flags)
        # Ordered repeat transition:
        #   <consumed, state, count> -> <consumed + unit_length, unit_state, count + 1>
        # Greedy and lazy modes differ only in the order of pushed candidates.
        # The repeat frame is restored when a later sequence operand rejects a
        # candidate; no capture mutation escapes that candidate.
        limit = quantifier.maximum || characters.length - cursor + 1
        accepted = []
        visit = lambda do |consumed, state_captures, count|
          current = [consumed, state_captures]
          if quantifier_accepts_count?(quantifier, count) && quantifier.mode == :lazy
            accepted << current unless accepted.include?(current)
            return if count >= limit
          end
          if count >= limit
            accepted << current unless accepted.include?(current) || count < quantifier.minimum
            return
          end

          repetition_flags = flags.merge(skip_fold_marker: !expanded_fold_operand?(quantifier.expression) &&
                                                    !simple_fold_operand?(quantifier.expression))
          repetition_state = state_captures
          if repetition_state.key?(:__quantifier_expanded_fold)
            repetition_state = repetition_state.dup
            repetition_state.delete(:__quantifier_expanded_fold)
            repetition_state.delete(:__quantifier_expanded_optional)
          end
          tree_results(quantifier.expression, characters, cursor + consumed, repetition_state,
                       repetition_flags).each do |length, inner|
            inner = clear_repeated_absence_captures(quantifier.expression, inner)
            expanded_fold = expanded_fold_boundary_state?(inner)
            expanded_fold_value = inner[:__group_expanded_literal_fold] || inner[:__expanded_literal_fold]
            inner = clear_fold_boundary_markers(inner)
            if expanded_fold && count.zero?
              inner = inner.merge(__quantifier_expanded_fold: expanded_fold_value)
              inner = inner.merge(__quantifier_expanded_optional: true) if quantifier.minimum.zero?
            end
            if quantifier.maximum.nil? && quantifier.expression.is_a?(SemanticBytecode::Group) &&
               quantifier.expression.capture && length.positive? &&
               repeated_capture_keeps_fold_origin?(quantifier.expression, inner)
              inner = inner.dup
              inner[:__class_capture_numbers] = Array(inner[:__class_capture_numbers])
              inner[:__class_capture_numbers] << quantifier.expression.number
            end
            if quantifier.maximum.nil? && quantifier.expression.is_a?(SemanticBytecode::Group) &&
               quantifier.expression.capture && length.positive? &&
               reverse_literal_capture_origin?(quantifier.expression.body, characters,
                                               cursor + consumed, length)
              inner = inner.dup
              inner[:__reverse_literal_capture_numbers] =
                Array(inner[:__reverse_literal_capture_numbers])
              inner[:__reverse_literal_capture_numbers] << quantifier.expression.number
            end
            if length.zero?
              expression = quantifier.expression
              expression = expression.body if expression.is_a?(SemanticBytecode::Group)
              if count.positive? && consumed.positive? &&
                 expression.is_a?(SemanticBytecode::Sequence)
                accepted << [consumed, inner] if quantifier_accepts_count?(quantifier, count + 1)
                next
              end

              accepted << [consumed, inner] if quantifier_accepts_count?(quantifier, count + 1)
              visit.call(consumed, inner, count + 1) if count + 1 < quantifier.minimum
              next
            end
            visit.call(consumed + length, inner, count + 1)
          end
          accepted << current if quantifier.mode != :lazy && quantifier_accepts_count?(quantifier, count) &&
                                 !accepted.include?(current)
        end
        visit.call(0, captures, 0)
        return [] if accepted.empty?

        if quantifier.mode != :lazy && quantifier.maximum != quantifier.minimum &&
           nullable_single_quantifier?(quantifier.expression) &&
           !lazy_nullable_body?(quantifier.expression)
          accepted = accepted.group_by(&:first).values.flat_map do |candidates|
            length = candidates.first.first
            if length.zero? && candidates.length > 1
              candidates
            else
              [candidates.last]
            end
          end.sort_by { |length, _state| -length }
          group = quantifier.expression
          accepted = accepted.map do |length, state|
            next [length, state] if quantifier.maximum && length >= quantifier.maximum
            next [length, state] unless length.positive? || state.key?(group.number)

            next_state = state.dup
            next_state[group.number] = [cursor + length, cursor + length]
            [length, next_state]
          end
        end

        if quantifier.lazy_exact
          # MRI tries the complete exact repetition before its zero-repeat
          # fallback. This differs from a normal lazy range.
          accepted.sort_by! { |length, _state| length.zero? ? 1 : 0 }
        end

        return accepted unless anchor_class_quantifier_fallback?(quantifier, accepted)

        zero_width = accepted.find { |length, _state| length.zero? }
        zero_width ? [zero_width] : accepted
      end

      def quantifier_accepts_count?(quantifier, count)
        return count >= quantifier.minimum unless quantifier.lazy_exact

        count.zero? || count == quantifier.maximum
      end

      def repeated_capture_keeps_fold_origin?(group, captures)
        body = group.body
        return true if capture_body_has_class?(body)

        literal = if body.is_a?(SemanticBytecode::Sequence) && body.parts.length == 1
                    body.parts.first
                  else
                    body
                  end
        return true unless literal.is_a?(SemanticBytecode::Literal)

        return true unless reverse_fold_source_literal?(literal.value)

        span = captures[group.number]
        span && @characters[span[0]...span[1]].join == literal.value
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
      def anchor_class_quantifier_fallback?(quantifier, accepted)
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
            nonzero_results = tree_results(quantifier.expression, characters, cursor + consumed, state_captures, flags).filter_map do |length, inner|
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
                        tree_results(quantifier.expression, characters, characters.length, captures, flags).any? do |length, _state|
                          length.zero?
                        end
        limit = quantifier.maximum || [characters.length - cursor + (nullable_body ? 1 : 0), 1].max
        consumed = 0
        current = captures
        count = 0
        accepted = quantifier.minimum.zero? ? [[0, current]] : []
        while count < limit
          result = tree_results(quantifier.expression, characters, cursor + consumed, current, flags).find do |length, _state|
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
        accepted = []
        limit = quantifier.maximum || characters.length - cursor + 1
        visit = lambda do |consumed, state, count|
          current = [consumed, state]
          if count >= limit
            accepted << current if count >= quantifier.minimum
            next
          end

          results = tree_results(quantifier.expression, characters, cursor + consumed, state, flags)
          if results.empty?
            accepted << current if count >= quantifier.minimum
            next
          end

          zero_seen = false
          results.each do |length, inner|
            if length.zero?
              next unless zero_width_nested_unit_valid?(quantifier.expression, characters,
                                                        cursor + consumed, state, flags)

              accepted << [consumed, inner] if count + 1 >= quantifier.minimum
              zero_seen = true
              next
            end

            break if zero_seen

            visit.call(consumed + length, inner, count + 1)
          end
          accepted << current if count >= quantifier.minimum
        end
        visit.call(0, captures, 0)
        accepted.uniq
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
        return !tree_results(node, characters, cursor, captures, flags).empty? unless
          node.is_a?(SemanticBytecode::Quantifier)
        return true if node.minimum.zero?
        return zero_width_nested_unit_valid?(node.expression, characters, cursor, captures, flags) if
          node.is_a?(SemanticBytecode::Quantifier)

        !tree_results(node, characters, cursor, captures, flags).empty?
      end

      def transition_lengths(label, characters, cursor, captures, flags = {})
        opcode, operand = label
        return flat_assertion_lengths(operand.variants, characters, cursor, captures, flags) if
          opcode == :match_alternation_atom
        return quantifier_lengths(operand, characters, cursor) if opcode == :match_quantifier
        return grapheme_cluster_lengths(characters, cursor) || [] if opcode == :match_escape && operand.kind == :grapheme

        length = transition_length(label, characters, cursor, flags, captures)
        length ? [length] : []
      end

      def transitions_for(state)
        @automaton.transitions.filter_map do |key, target|
          source, label, tags = key
          [label, target, tags || []] if source == state
        end
      end

      # Apply tag effects after a transition succeeds. The operation itself
      # remains responsible for semantic matching. Tags provide a stable VM
      # event stream for capture, choice, repeat, assertion, and call edges.
      def apply_tag_effects(tags, label, cursor, length, captures)
        Array(tags).each do |tag|
          case tag.kind
          when :capture
            operand = tag.value
            next unless operand.respond_to?(:capture) && operand.capture

            captures[operand.number] = [cursor, cursor + length]
            captures[operand.name] = [cursor, cursor + length] if operand.name
          when :choice, :repeat, :assertion, :call
            @state.push_backtrack_point([label, cursor, length, tag.kind])
            @state.pop_backtrack_point
          end
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
        # Primitive transition:
        #   input  = <opcode, operand, cursor, captures, flags>
        #   output = one length or nil
        # A positive length consumes that many input characters. Zero is a
        # successful zero-width operation. Nil is failure and changes nothing.
        opcode, operand = label
        case opcode
        when :match_literal
          # literal: compare the operand's compiled value with input at cursor.
          value = literal_characters(operand, flags)
          if flags[:ignorecase]
            if captures[:__lookbehind_reverse_fold] && cursor >= characters.length &&
               operand.casefold && operand.casefold.length > operand.value.length
              return 0
            end

            casefold_lengths(value.join, characters, cursor,
                             folded: operand.casefold,
                             source_width: operand.source_width,
                             folded_width: operand.folded_width,
                             expanded_only: flags[:lookbehind_casefold] &&
                                            !flags[:lookbehind_fold_source],
                             overlap: captures[:__lookbehind_overlap]).first
          else
            input_codepoints = characters[cursor, value.length]&.map(&:ord)
            input_codepoints == value.map(&:ord) ? value.length : nil
          end
        when :match_class
          # class: return the first accepted source width from the class table.
          class_match_lengths(operand, characters, cursor, flags).first
        when :match_any
          # any: consume one character unless the dot rule rejects it.
          if captures[:__lookbehind_overlap]
            0
          elsif cursor < characters.length &&
                (flags[:multiline] || operand.value != "." || characters[cursor] != "\n")
            1
          end
        when :match_escape
          # escape: consume the width defined by the compiled escape operand.
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
            return nil unless cursor < characters.length &&
                              Onibi::CharacterPredicates.linebreak?(characters[cursor], encoding: flags[:encoding])

            characters[cursor] == "\r" && characters[cursor + 1] == "\n" ? 2 : 1
          when :match_reset
            0
          when :start_match
            cursor == @state.search_origin ? 0 : nil
          else
            if cursor < characters.length &&
               Onibi::CharacterPredicates.escape_matches?(operand.kind, characters[cursor], encoding: flags[:encoding])
              1
            end
          end
        when :match_property
          # property: return the first accepted width from the property table.
          property_match_lengths(operand, characters, cursor, flags).first
        when :match_quantifier
          # quantifier: use the operand's ordered repeat policy for one length.
          quantifier_length(operand, characters, cursor)
        when :match_group
          # group: calculate the body's fixed-width fast-path result.
          sequence_length(operand.body, characters, cursor)
        when :match_backreference
          # backreference: consume the captured source width after comparison.
          backreference_length(operand, characters, cursor, captures, flags)
        when :match_conditional
          # conditional: calculate the selected branch's fixed-width result.
          conditional_length(operand, characters, cursor, captures)
        when :match_atomic_group
          # atomic_group: calculate the committed body's fixed-width result.
          sequence_length(operand.body, characters, cursor)
        when :match_option_group
          # option_group: calculate the body under scoped flags.
          option_group_length(operand, characters, cursor, flags)
        when :match_absence
          # absence: return the complement probe's bounded fast-path width.
          absence_length(operand, characters, cursor, flags)
        when :match_assertion
          # assertion: return zero only when the assertion succeeds.
          assertion_length(operand, characters, cursor, flags)
        when :test_anchor
          # anchor: return zero only when the anchor condition succeeds.
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

      def flat_absence_repeat_lengths(quantifier, characters, cursor, captures, flags)
        return [] unless quantifier.is_a?(SemanticBytecode::Quantifier)

        frontier = [0]
        results = []
        maximum = quantifier.maximum || characters.length - cursor + 1
        maximum.times do |count|
          zero_lengths = []
          next_frontier = frontier.flat_map do |consumed|
            absence = quantifier.expression
            flat_literal_absence_lengths(absence, characters, cursor + consumed, captures, flags).filter_map do |length|
              if length.zero?
                zero_lengths << consumed
                next
              end

              consumed + length
            end
          end.uniq
          results.concat(zero_lengths.uniq) if count + 1 >= quantifier.minimum
          break if next_frontier.empty?

          frontier = next_frontier
          results.concat(frontier) if count + 1 >= quantifier.minimum
        end
        quantifier.mode == :lazy ? results : results.reverse
      end

      def quantifier_lengths(quantifier, characters, cursor, captures = {}, flags = {})
        if quantifier.expression.is_a?(SemanticBytecode::Group) && quantifier.maximum.nil?
          body = quantifier.expression.body
          body = body.parts.first if body.is_a?(SemanticBytecode::Sequence) && body.parts.one?
          if body.is_a?(SemanticBytecode::Quantifier) && body.minimum.zero? && body.maximum == 1
            return nullable_group_repeat_lengths(quantifier, body, characters, cursor, captures, flags)
          end
        end

        if quantifier.expression.is_a?(SemanticBytecode::Group) ||
           quantifier.expression.is_a?(SemanticBytecode::OptionGroup)
          expression = quantifier.expression
          scoped_flags = flags
          if expression.is_a?(SemanticBytecode::OptionGroup)
            scoped_flags = flags.dup
            scoped_flags[:ignorecase] = expression.ignorecase unless expression.ignorecase.nil?
            scoped_flags[:multiline] = expression.multiline unless expression.multiline.nil?
          end
          body = expression.body
          unit = sequence_length(body, characters, cursor, scoped_flags)
          return [] unless unit&.positive?

          count = 0
          consumed = 0
          limit = quantifier.maximum || characters.length
          lengths = []
          while count < limit
            unit_length = sequence_length(body, characters, cursor + consumed, scoped_flags)
            break unless unit_length&.positive?

            count += 1
            consumed += unit_length
            lengths << consumed if count >= quantifier.minimum
          end
          return [lengths.last] if quantifier.mode == :possessive

          return quantifier.mode == :lazy ? lengths : lengths.reverse
        end

        count = 0
        consumed = 0
        limit = quantifier.maximum || (characters.length - cursor)
        while count < limit && cursor + consumed < characters.length
          width = case quantifier.expression
                  when SemanticBytecode::Backreference
                    backreference_length(quantifier.expression, characters, cursor + consumed, captures, flags)
                  when SemanticBytecode::Literal
                    transition_length([:match_literal, quantifier.expression], characters, cursor + consumed, flags)
                  else
                    atom_matches?(quantifier.expression, characters[cursor + consumed], flags) ? 1 : nil
                  end
          break unless width&.positive?

          count += 1
          consumed += width
        end
        return [] if count < quantifier.minimum

        if quantifier.lazy_exact
          exact = quantifier.maximum
          return [0] unless exact && count >= exact

          return [0, consumed] if exact == count
          return [0, exact * (consumed / count)] if exact.positive? && count >= exact
        end

        lengths = (quantifier.minimum..count).to_a
        return [lengths.last] if quantifier.mode == :possessive

        quantifier.mode == :lazy ? lengths : lengths.reverse
      end

      def nullable_group_repeat_lengths(quantifier, body, characters, cursor, captures, flags)
        limit = [characters.length - cursor, 1].max
        frontier = [0]
        lengths = []
        count = 0
        while count < limit
          next_frontier = []
          frontier.each do |consumed|
            quantifier_lengths(body, characters, cursor + consumed, captures, flags).each do |length|
              total = consumed + length
              next if total == consumed || next_frontier.include?(total)

              next_frontier << total
            end
          end
          count += 1
          lengths.concat(frontier)
          break if next_frontier.empty?

          frontier = next_frontier
        end
        lengths.concat(frontier) unless frontier.empty?
        lengths = lengths.uniq.select { |length| length >= 0 }
        lengths = lengths.select { |length| count >= quantifier.minimum }
        quantifier.mode == :lazy ? lengths : lengths.reverse
      end

      def captures_for(label, cursor, length, captures, characters = nil, flags = {})
        # Capture transition:
        #   input  = <label, cursor, length, local_state>
        #   output = local_state plus the operand's capture span
        # Captures are written only after the caller accepts a stack result.
        # Failed candidates therefore leave the caller's local state intact.
        opcode, operand = label
        if opcode == :match_absence
          capture_absence(operand.body, cursor, length, captures) if operand.body
          return
        end
        if opcode == :match_quantifier &&
           operand.expression.is_a?(SemanticBytecode::Group)
          group = operand.expression
          return unless group.capture
          if length.zero?
            body = group.body
            body = body.parts.first if body.is_a?(SemanticBytecode::Sequence) && body.parts.one?
            return unless body.is_a?(SemanticBytecode::Quantifier) && body.minimum.zero? && body.maximum == 1

            captures[group.number] = [cursor, cursor]
            captures[group.name] = [cursor, cursor] if group.name
            return
          end

          captures[group.number] ||= [cursor, cursor + length]
          captures[group.name] ||= [cursor, cursor + length] if group.name
          return
        end
        return unless opcode == :match_group && operand.capture

        captures[operand.number] = [cursor, cursor + length]
        captures[operand.name] = [cursor, cursor + length] if operand.name
        return unless characters

        nested = tree_results(operand.body, characters, cursor, captures, flags).find do |inner_length, _inner|
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

          next if !flags[:ignorecase] &&
                  (captures[:__captured_expanded_fold] ||
                   (captures[:__expanded_literal_fold] &&
                    Onibi::UnicodeProperties.greek?(captures[:__expanded_literal_value].to_s)) ||
                   %i[simple_fold_source expanded_tail].include?(
                     captures[:__group_expanded_literal_boundary]&.fetch(:kind, nil)
                   ))

          value = characters[span[0]...span[1]]
          candidate = characters[cursor, value.length]
          if flags[:ignorecase] && value.length == 1 && candidate&.length == 1 &&
             value.first.encoding == Encoding::UTF_8 && !value.first.ascii_only? &&
             Onibi::UnicodeProperties.greek?(value.first) &&
             value.first.downcase(:fold).each_char.one? &&
             value.first == value.first.upcase &&
             value.first != value.first.downcase(:fold) &&
             candidate.first == value.first.downcase(:fold)
            next
          end
          matched = flags[:ignorecase] ? simple_casefold_equal?(value.join, candidate.join) : candidate == value
          matched = value.join.downcase(:fold) == candidate.join.downcase(:fold) if !matched && flags[:ignorecase] && cursor + value.length < characters.length
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
        branch = conditional.yes_branch if !captures.key?(key) &&
                                           captures.fetch(:__absence_captures, {}).key?(key)
        return [] unless branch

        tree_results(branch, characters, cursor, captures, flags)
      end

      def atom_matches?(expression, character, flags = {})
        case expression
        when SemanticBytecode::Literal
          value = literal_string(expression, flags)
          flags[:ignorecase] ? value.casecmp?(character) : value == character
        when SemanticBytecode::CharacterClass
          compiled_class_match?(expression, character, flags)
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

      def literal_string(expression, flags)
        return expression.value unless flags[:ascii_escape_bytes] && flags[:encoding] == Encoding::ASCII_8BIT

        expression.value.bytes.pack("C*").force_encoding(Encoding::ASCII_8BIT)
      end

      def literal_characters(expression, flags)
        literal_string(expression, flags).each_char.to_a
      end

      # Return all lengths that one property bytecode operand can consume.
      # MRI keeps these reverse case-fold edges in its generated Onigmo table.
      # The direct edge stays first, so an unconstrained match keeps MRI's
      # leftmost-shortest result. Backtracking can then try a fold expansion
      # when a following anchor or assertion requires it.
      def property_match_lengths(operand, characters, cursor, flags)
        return [] if cursor >= characters.length

        character = if flags[:encoding] == Encoding::ASCII_8BIT
                      characters[cursor]
                    else
                      unicode_character(characters[cursor])
                    end
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
                   when SemanticBytecode::OptionGroup
                     option_group_length(part, characters, position, flags)
                   when SemanticBytecode::Alternation
                     part.branches.lazy.map { |branch| sequence_length(branch, characters, position, flags) }.
                       find(&:itself)
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

      # Every scoped operand uses the same frame stack.  The frame fields are
      # intentionally neutral: each operand records only the checkpoints it
      # needs, while the enclosing invocation owns lifetime and rollback.
      def with_scope_frame(kind, characters, cursor)
        frame = @state.new_frame(
          kind: kind,
          absent_start: cursor,
          absent_end: characters.length,
          probe_position: cursor,
          possible_points: [],
          body_checkpoints: [],
          capture_checkpoints: []
        )
        @state.with_frame(frame) { yield frame }
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

      def flat_literal_absence_lengths(node, characters, cursor, captures = {}, flags = {})
        if node.respond_to?(:flat_atoms) && node.flat_atoms && !node.flat_atoms.empty?
          return flat_atom_absence_lengths(node.flat_atoms, characters, cursor, captures, flags)
        end

        delimiters = literal_absence_delimiters(node.body)
        return unless delimiters

        limit = characters.length - cursor
        boundary = cursor.upto(characters.length).find do |position|
          delimiters.any? do |delimiter|
            characters[position, delimiter.length].to_a.join == delimiter
          end
        end
        maximum = boundary ? boundary - cursor : limit
        maximum.downto(0).to_a
      end

      def flat_literal_absence_results(node, characters, cursor, captures = {}, flags = {})
        return [[0, captures]] if node.flat_atoms&.empty?

        return flat_literal_absence_lengths(node, characters, cursor, captures, flags).map { |length| [length, {}] } unless
          node.flat_atoms&.flatten&.any? { |atom| atom.is_a?(SemanticBytecode::CaptureAtom) }

        variants = node.flat_atoms.first.is_a?(Array) ? node.flat_atoms : [node.flat_atoms]
        boundary = cursor.upto(characters.length).find do |position|
          variants.any? do |variant|
            flat_assertion_results([variant], characters, position, captures, flags).any?
          end
        end
        return flat_literal_absence_lengths(node, characters, cursor, captures, flags).map { |length| [length, {}] } unless boundary

        variant = variants.find do |candidate|
          flat_assertion_results([candidate], characters, boundary, captures, flags).any?
        end
        length, state = flat_assertion_results([variant], characters, boundary, captures, flags).first
        maximum = [boundary - cursor + length - 1, characters.length - cursor].min
        maximum.downto(0).map { |candidate| [candidate, state] }
      end

      def flat_nullable_capture_absence_results(operand, characters, cursor, captures, flags)
        found = cursor.upto(characters.length - 1).find do |position|
          transition_results([:match_literal, operand.atom], characters, position, captures, flags).any?
        end
        if found
          span = [found, found + 1]
          captured = captures.merge(operand.number => span)
          captured[operand.name] = span if operand.name
          [[0, captured]]
        else
          [[0, {}]]
        end
      end

      def flat_absence_probe_results(program, characters, cursor, captures, flags, capture_program: nil,
                                     capture_requires_end: false)
        frame = @state.push_absence_frame(
          resume_pc: nil, body_pc: nil, absent_start: cursor, absent_end: characters.length,
          probe_position: cursor, possible_points: [], body_checkpoints: [], capture_checkpoints: []
        )
        current = captures
        position = cursor
        while position < frame.absent_end
          bounded = characters[0...frame.absent_end]
          results = flat_probe_results(program, bounded, position, current, flags)
          partial_state = nil
          if results.empty? && capture_program
            partial = flat_probe_results(capture_program, bounded, position, current, flags).first
            if partial && partial.last.values.any? { |span| span.is_a?(Array) && span.last == bounded.length }
              partial_state = partial.last
            end
          end
          record_absence_checkpoint(frame, position, results, current)
          if results.empty?
            current = partial_state || (capture_requires_end ? captures : (capture_program ? current : captures))
          else
            length, state = results.first
            frame.tighten_absent_end(position + length - 1)
            current = state
          end
          position += 1
        end
        [[frame.absent_end - cursor, current || captures]]
      ensure
        @state.pop_absence_frame(frame) if frame && @state.current_frame.equal?(frame)
      end

      def flat_absence_assertion_results(assertion, characters, cursor, flags)
        first_match = cursor.upto(characters.length).find do |position|
          flat_assertion_match?(assertion, characters, position, {}, flags)
        end
        return [] unless first_match

        if first_match > cursor
          first_match.downto(cursor).map { |position| [position - cursor, {}] }
        else
          next_failure = (cursor + 1).upto(characters.length).find do |position|
            !flat_assertion_match?(assertion, characters, position, {}, flags)
          end
          if next_failure
            [[1, { __match_start: next_failure, __match_end: next_failure + 1 }]]
          else
            [[0, { __match_start: characters.length, __match_end: characters.length,
                   __zero_absence: true }]]
          end
        end
      end

      def flat_probe_results(program, characters, cursor, captures, flags)
        instruction = Onibi::IRGen::YARVIR::Instruction.new(opcode: :semantic_flat, operand: program)
        wrapper = Onibi::IRGen::YARVIR::Program.new(instructions: [instruction], flags: flags)
        FlatExecutor.new(wrapper).send(:execute_flat_semantic_vm, cursor, characters, captures, flags)
      end

      def flat_quantified_absence_lengths(node, characters, cursor, flags)
        limit = characters.length - cursor
        run = 0
        unit_width = node.atoms.sum { |atom| atom.is_a?(SemanticBytecode::Literal) ? atom.value.each_char.count : 1 }
        if unit_width > 1
          boundary = cursor.upto(characters.length).find do |probe|
            local = 0
            while probe + local < characters.length &&
                  flat_assertion_lengths([node.atoms], characters, probe + local, {}, flags).any?
              local += unit_width
            end
            if local >= node.minimum * unit_width
              run = local
              true
            end
          end
          return [boundary ? [boundary - cursor + run - 1, limit].min : limit]
        end
        if node.atoms.first.is_a?(SemanticBytecode::AlternationAtom)
          boundary = cursor.upto(characters.length).find do |probe|
            local = 0
            while probe + local < characters.length &&
                  flat_assertion_lengths([node.atoms], characters, probe + local, {}, flags).any?
              local += 1
            end
            if local >= node.minimum
              run = local
              true
            end
          end
          return [boundary ? [boundary - cursor + (run + 1) / 2, limit].min : limit]
        end
        while run < limit && flat_assertion_lengths([node.atoms], characters, cursor + run, {}, flags).any?
          widths = flat_assertion_lengths([node.atoms], characters, cursor + run, {}, flags)
          run += widths.select(&:positive?).min || unit_width
        end
        if run < node.minimum
          if node.minimum == 1
            boundary = cursor.upto(characters.length).find do |probe|
              flat_assertion_lengths([node.atoms], characters, probe, {}, flags).any?
            end
            maximum = boundary ? boundary - cursor : limit
            return maximum.downto(0).to_a
          end

          boundary = cursor.upto(characters.length).find do |probe|
            flat_repeated_match?(node, characters, probe, flags)
          end
          maximum = boundary ? boundary - cursor + node.minimum - 1 : limit
          return maximum.downto(0).to_a
        end

        maximum = node.minimum >= 2 ? (run + node.minimum - 1) / 2 : run / 2
        [maximum, limit].min.downto(0).to_a
      end

      def flat_nullable_absence_repeat_results(atom, characters, cursor, flags)
        run = 0
        while cursor + run < characters.length &&
              flat_assertion_lengths([[atom]], characters, cursor + run, {}, flags).any?
          run += 1
        end
        return [[0, {}]] if run.zero? && cursor == characters.length
        return [] if run.zero?

        maximum = run / 2
        return [[0, { __match_start: cursor + run, __zero_absence: true }]] if maximum.zero? &&
                                                                              cursor + run == characters.length

        maximum.downto(0).map { |length| [length, {}] }
      end

      def flat_repeated_match?(node, characters, cursor, flags)
        lengths = [0]
        node.minimum.times do
          lengths = lengths.flat_map do |consumed|
            flat_assertion_lengths([node.atoms], characters, cursor + consumed, {}, flags).map do |width|
              consumed + width
            end
          end.select(&:positive?).uniq
        end
        !lengths.empty?
      end

      def flat_atom_absence_lengths(atoms, characters, cursor, captures, flags)
        variants = atoms.first.is_a?(Array) ? atoms : [atoms]
        limit = characters.length - cursor
        boundary = cursor.upto(characters.length).find do |position|
          variants.any? do |variant|
            flat_assertion_lengths([variant], characters, position, captures, flags).any?
          end
        end
        body_width = if boundary && boundary < characters.length
                       variants.flat_map do |variant|
                         flat_assertion_lengths([variant], characters, boundary, captures, flags)
                       end.max.to_i
                     end
        maximum = if boundary && boundary < characters.length
                    [boundary - cursor + body_width - 1, limit].min
                  else
                    limit
                  end
        maximum.downto(0).to_a
      end

      def literal_absence_delimiters(node)
        return [node.value] if node.is_a?(SemanticBytecode::Literal) && node.casefold.nil? && !node.value.empty?

        if node.is_a?(SemanticBytecode::Sequence)
          values = node.parts.map { |part| literal_absence_delimiters(part) }
          return [values.flatten.join] if values.all? { |items| items&.one? }
        elsif node.is_a?(SemanticBytecode::Alternation)
          values = node.branches.map { |branch| literal_absence_delimiters(branch) }
          return values.flatten if values.all? && values.all? { |items| items&.one? }
        end
        nil
      end

      def literal_assertion_values(node)
        return [node.value] if node.is_a?(SemanticBytecode::Literal) && node.casefold.nil?
        return literal_absence_delimiters(node) if node.is_a?(SemanticBytecode::Sequence) ||
                                                   node.is_a?(SemanticBytecode::Alternation)

        nil
      end

      # The VM dispatch keeps all OP_ABSENT state transitions in one method.
      # rubocop:disable Metrics/BlockLength
      def absence_results(node, characters, cursor, captures, flags)
        # Absence transition:
        #   input  = <absence(body), cursor, captures, flags>
        #   probe  = execute body at each bounded probe position
        #   output = complement lengths with a restored frame checkpoint
        # The frame stores probe positions, body results, and capture
        # checkpoints. Results remain ordered so the enclosing sequence keeps
        # the same choice semantics as the compiled bytecode.
        # A literal delimiter is a safe fast path only when its body has no
        # capture. The wrapped body still owns capture state in MRI.
        # The literal delimiter shortcut performs exact string search. Case-folded
        # absence must use the bytecode probe, because the forbidden body may match
        # a different code point or a multi-codepoint fold.
        delimiter = literal_value(node.body) unless capture_numbers(node.body).any? || flags[:ignorecase]
        return absence_lengths(node, characters, cursor, flags).map { |length| [length, captures] } if delimiter

        frame = @state.push_absence_frame(
          absent_start: cursor,
          absent_end: characters.length,
          probe_position: cursor,
          possible_points: [],
          body_checkpoints: [],
          capture_checkpoints: []
        )

        begin
          body_at_cursor = tree_results(node.body, characters, cursor, captures, flags)
          first_result = body_at_cursor.find { |length, _state| length.positive? } || body_at_cursor.first
          first_length = first_result&.first
          first_state = first_result&.last || {}
          zero_at_cursor = first_length&.zero?
          consuming_at_cursor = first_length&.positive?
          return [] if zero_at_cursor && consuming_at_cursor

          if zero_at_cursor && !consuming_at_cursor
            later_consuming = cursor.upto(characters.length).any? do |position|
              tree_results(node.body, characters, position, captures, flags).any? do |length, _state|
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

          if !flags[:ignorecase] && bounded_quantifier_body?(node.body)
            return bounded_quantifier_absence_results(node.body, characters, cursor, captures,
                                                      flags)
          end

          if !flags[:ignorecase] && nested_unbounded_quantifier_body?(node.body)
            return nested_unbounded_quantifier_absence_results(node.body, characters, cursor, captures, flags)
          end

          quantified_suffix = flags[:ignorecase] ? nil : quantified_suffix_absence_results(node.body, characters, cursor, captures, flags)
          return quantified_suffix if quantified_suffix

          quantified = quantified_absence_length(node.body, characters, cursor, flags)
          if quantified
            body_results = tree_results(node.body, characters, cursor, captures, flags)
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
            results = tree_results(node.body, characters, position, captures, flags)
            record_absence_checkpoint(frame, position, results, captures)
            if results.empty?
              candidate = sequence_failure_state(node.body, characters, position, captures, flags)
              failure_state = candidate.first if candidate && candidate.last == characters.length && candidate.first.keys.any? { |key| key.is_a?(Integer) }
              next
            end

            preferred = frame.preferred_body_result(position, results)
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
            if nested_unbounded_quantifier_body?(node.body) && body_result
              outer_number = capture_numbers(node.body).first
              outer_value = body_result.last[outer_number]
              inner_captures = { outer_number => outer_value } if outer_number && outer_value
            end
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
        ensure
          @state.pop_frame if @state.current_frame.equal?(frame)
        end
      end
      # rubocop:enable Metrics/BlockLength

      def record_absence_checkpoint(frame, position, results, captures)
        frame.probe_position = position
        frame.record_body_checkpoint(position, results, captures)
        branches = results.filter_map do |length, state|
          branch = state[:__match_alternative_index]
          [branch, length] if branch.is_a?(Integer)
        end
        branches.each { |branch, length| frame.record_branch_checkpoint(position, branch, length) }
      end

      def absence_capture_checkpoint_state(frame, fallback)
        checkpoint = frame.restorable_capture_checkpoint
        checkpoint ? checkpoint[2].dup : fallback.dup
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
          return true if tree_results(body, characters, position, captures, flags).any?
        end
        false
      end

      def prefix_quantifier_match_exists?(body, characters, cursor, captures, flags)
        scope = quantifier_suffix_scope(body)
        return false unless scope

        minimum = minimum_node_width(scope.first.expression)
        cursor.upto(characters.length) do |position|
          results = tree_results(scope.first.expression, characters, position, captures, flags)
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
          results = tree_results(body, characters, position, captures, flags)
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
        return state if tree_results(body, characters, cursor, captures, flags).any? do |length, _checkpoint|
          cursor + length == endpoint
        end

        expression = scope.first.expression
        minimum = minimum_node_width(expression)
        wide_seen = false
        candidate = nil
        cursor.upto([endpoint - 1, characters.length].min) do |position|
          tree_results(expression, characters, position, captures, flags).each do |length, checkpoint|
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
              suffix_matches = tree_results(
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
                               tree_results(
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
        suffix_matches = tree_results(suffix, characters, outer_span[1], captures, flags).any? do |length, _state|
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
        filtered = filter_bounded_absence_captures(body, state)
        candidates = [[length, filtered]]
        candidates << [length - 1, filtered] if length > 1
        candidates << [0, filtered] if length.positive?
        candidates
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
          candidate = tree_results(body, characters, position, captures, flags).find do |body_length, _inner|
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

          results = tree_results(body, characters, cursor, captures, flags)
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
            results = tree_results(body, characters, cursor, captures, flags)
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
          results = tree_results(body, characters, cursor, captures, flags)
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
            results = tree_results(body, characters, cursor, captures, flags)
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

        results = tree_results(body, characters, cursor, captures, flags)
        target = results.find { |length, _state| length == maximum + 1 }
        return unless target

        state = target.last.dup
        state.delete_if { |key, _value| key.is_a?(Symbol) && key.to_s.start_with?("__") }
        [[maximum, state]]
      end

      # Execute the two loops used by Onigmo's OP_ABSENT protocol.
      # Each probe uses the current absent end as its input boundary.
      def absence_bounded_probe_results(body, characters, cursor, captures, flags, preserve_failed_capture: false)
        frame = @state.new_absence_frame(
          kind: :absence,
          resume_pc: nil,
          body_pc: nil,
          absent_start: cursor,
          absent_end: characters.length,
          probe_position: cursor,
          possible_points: [],
          body_checkpoints: [],
          capture_checkpoints: []
        )
        @state.with_frame(frame) do
          current_captures = captures
          position = cursor
          while position < frame.absent_end
            frame.probe_position = position
            bounded = characters[0...frame.absent_end]
            results = tree_results(body, bounded, position, captures, flags)
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
              frame.record_capture_checkpoint(position, length, state, discard_capture, results.length > 1)
              boundary = if length.zero? && nested_nullable_repeat_body?(body)
                           position
                         else
                           position + length - 1
                         end
              frame.tighten_absent_end(boundary)
              current_captures = state
            end
            position += 1
          end

          state = (current_captures || captures).dup
          state.delete_if { |key, _value| key.is_a?(Integer) } if frame.capture_checkpoints.last&.fetch(3) && !bounded_wrapper_capture?(body)
          state.delete_if { |key, _value| key.is_a?(Symbol) && key.to_s.start_with?("__") }
          [[frame.absent_end - cursor, state]]
        ensure
          @state.pop_frame if @state.current_frame.equal?(frame)
        end
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
          length = tree_results(expression, characters, position, {}, flags)
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

          counts = tree_results(expression, characters, position, {}, flags).filter_map do |length, _state|
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

      def clear_fold_boundary_markers(captures)
        return captures unless captures.key?(:__expanded_literal_source) ||
                               captures.key?(:__group_expanded_literal_source)

        cleaned = captures.dup
        cleaned.delete(:__expanded_literal_source)
        cleaned.delete(:__expanded_literal_fold)
        cleaned.delete(:__expanded_literal_boundary)
        cleaned.delete(:__group_expanded_literal_source)
        cleaned.delete(:__group_expanded_literal_fold)
        cleaned.delete(:__group_expanded_literal_boundary)
        cleaned.delete(:__group_expanded_literal_prefix)
        cleaned
      end

      def expanded_fold_boundary_state?(captures)
        boundary = captures[:__group_expanded_literal_boundary] || captures[:__expanded_literal_boundary]
        boundary&.fetch(:kind, nil) == :expanded_tail
      end

      def expanded_fold_operand?(node)
        fold_boundary_for_node(node)&.fetch(:kind, nil) == :expanded_tail
      end

      def simple_fold_operand?(node)
        operand = boundary_operand(node)
        return false unless operand.is_a?(SemanticBytecode::Literal)

        variants = Onibi::UnicodeProperties.reverse_source_boundary_variants(operand.value.downcase(:fold))
        variants.include?(operand.value) || operand.fold_boundary&.fetch(:kind, nil) == :simple_fold_source
      end

      def optional_expanded_quantifier?(node)
        node.is_a?(SemanticBytecode::Quantifier) && node.minimum.zero? && expanded_fold_operand?(node.expression)
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
          position += 1 while tree_results(expression, characters, position, {}, flags).any? { |length, _state| length == 1 }
        end
        position - cursor
      end

      def quantified_atom_matches?(expression, characters, position, flags)
        atom = literal_value(expression)
        return characters[position, atom.length].join == atom if atom

        tree_results(expression, characters, position, {}, flags).any? { |length, _state| length == 1 }
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
            tree_results(part, characters, cursor + consumed, state, flags).map do |length, inner|
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
          results = tree_results(body, characters, position, captures, flags)
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
          tree_results(body, characters, position, captures, flags).none? do |length, state|
            length.zero? && (state[:__match_start] || position) == position
          end
        end || characters.length
        finish = if start == characters.length
                   start
                 else
                   (start + 1).upto(characters.length).find do |position|
                     tree_results(body, characters, position, captures, flags).any? do |length, state|
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
          return tree_results(body, characters, cursor, {}, flags).none? do |length, _state|
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
          results = tree_results(node.body, characters, position, {}, flags)
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
            length = tree_results(quantifier.expression, characters, position, {}, flags).map(&:first).select(&:positive?).max
            break unless length

            run += length
            position += length
          end
          return if run.zero?
          return if quantifier.minimum.to_i.positive? && run < quantifier.minimum

          return quantifier.minimum.to_i >= 2 ? (run + quantifier.minimum - 1) / 2 : run / 2
        end
        if quantifier.expression.is_a?(SemanticBytecode::Any)
          run = 0
          position = cursor
          while position < characters.length
            length = tree_results(quantifier.expression, characters, position, {}, flags)
                     .map(&:first).select(&:positive?).max
            break unless length

            run += length
            position += length
          end
          return if run.zero? && quantifier.minimum.to_i.positive?

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
                        tree_results(quantifier.expression, characters, position, {}, {}).any? do |length, _captures|
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
            next unless class_match?(node, candidate, flags)

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
        matched = compiled_class_match?(node, character, flags)
        return true if matched
        return true if flags[:ignorecase] && node.folded_characters&.include?(character)
        return false unless flags[:ignorecase]
        return false if node.value.start_with?("^")
        return false if node.value.include?("[") || node.value.include?(":") || node.value.include?("\\")

        folded = character.downcase(:fold)
        return false unless folded.each_char.one?

        compiled_class_match?(node, folded, flags.merge(ignorecase: true))
      end

      # The class predicate is a bytecode operand. Use its prebuilt table
      # for Unicode encodings after runtime character normalization.
      def compiled_class_match?(node, character, flags)
        return true if flags[:ignorecase] && node.folded_characters&.include?(character)

        table = flags[:ignorecase] ? node.compiled_insensitive : node.compiled_sensitive
        if table && UNICODE_ENCODINGS.include?(flags[:encoding]) && character.encoding == Encoding::UTF_8
          table.matches?(character)
        else
          Onibi::ClassPredicates.matches?(node.value, character,
                                          ignorecase: flags[:ignorecase],
                                          encoding: flags[:encoding])
        end
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

      def unwrap_literal_operand(node)
        node = node.body if node.is_a?(SemanticBytecode::Group) ||
                            node.is_a?(SemanticBytecode::OptionGroup) ||
                            node.is_a?(SemanticBytecode::AtomicGroup)
        node = node.parts.first if node.is_a?(SemanticBytecode::Sequence) && node.parts.one?
        node
      end

      def boundary_literal_operands(node)
        node = unwrap_literal_operand(node)
        return [node] if node.is_a?(SemanticBytecode::Literal)
        return [] unless node.is_a?(SemanticBytecode::Alternation)

        node.branches.flat_map { |branch| boundary_literal_operands(branch) }
      end

      def branch_fold_literals(node)
        case node
        when SemanticBytecode::Literal then [node]
        when SemanticBytecode::Sequence then node.parts.flat_map { |part| branch_fold_literals(part) }
        when SemanticBytecode::Group, SemanticBytecode::OptionGroup, SemanticBytecode::AtomicGroup
          branch_fold_literals(node.body)
        else []
        end
      end

      def option_group_ignorecase?(node)
        return node.ignorecase == true if node.is_a?(SemanticBytecode::OptionGroup)

        false
      end

      def class_expanded_fold(node, character)
        return unless character && node.respond_to?(:casefolds)

        # Unicode property classes already perform their own case-insensitive
        # membership test.  Do not add a literal-fold boundary marker for
        # them.  MRI keeps that marker for explicit literal classes only;
        # applying it to a property class rejects valid following operands.
        return if node.value.include?("\\") || node.value.include?(":")

        pair = node.casefolds.find { |source, _fold| source == character }
        fold = pair&.[](1)
        fold ||= character.downcase(:fold) if node.fold_boundaries&.key?(character)
        boundary = simple_fold_boundary_for(node, character)
        return fold if fold && boundary&.fetch(:kind, nil) == :simple_fold_source

        fold if fold && fold.length > character.length
      end

      def casefold_equal?(left, right)
        left.downcase(:fold) == right.downcase(:fold)
      end

      def simple_casefold_equal?(left, right)
        return true if left == right

        left_fold = left.downcase(:fold)
        right_fold = right.downcase(:fold)
        return false if left.length > 1 && right_fold.length != right.length
        if left.each_char.all? { |character| Onibi::UnicodeProperties.greek?(character) } &&
           right.each_char.all? { |character| Onibi::UnicodeProperties.greek?(character) }
          return left_fold == right_fold
        end

        return left_fold == right_fold if left_fold.length != left.length || right_fold.length != right.length

        right_fold == left.downcase
      end

      def casefold_lengths(value, characters, cursor, folded: nil, source_width: nil,
                           folded_width: nil, expanded_only: false, overlap: 0)
        overlap = overlap.to_i

        if value.encoding != Encoding::UTF_8 && value.encoding != Encoding::ASCII_8BIT && !value.ascii_only?
          slice = characters[cursor, value.length]
          return slice && slice.join == value ? [value.length] : []
        end

        folded_value = folded || value.downcase(:fold)
        folded_value = folded_value[overlap..] || "" if overlap.positive?
        folded_value = folded_value.encode(Encoding::UTF_8) unless [Encoding::UTF_8, Encoding::ASCII_8BIT].include?(folded_value.encoding)
        maximum = folded_width || folded_value.length
        source_width ||= value.length
        minimum = expanded_only && maximum > source_width ? source_width + 1 : 1
        (minimum..maximum).select do |length|
          slice = characters[cursor, length]
          next false unless slice && slice.length == length

          joined = slice.join
          # MRI applies Unicode casefold only for Unicode input. In other
          # encodings, keep non-ASCII characters on the exact-match path.
          if joined.encoding != Encoding::UTF_8 && !joined.ascii_only?
            next joined == value if joined.encoding == Encoding::ASCII_8BIT

            next false
          end

          folded_slice = if joined.encoding == Encoding::ASCII_8BIT
                           joined.downcase(:fold)
                         else
                           joined.encode(Encoding::UTF_8).downcase(:fold)
                         end
          folded_value == folded_slice
        end
      end

      def property_matches?(name, character, ignorecase, encoding = nil)
        cache_key = [name, character, ignorecase, encoding]
        return @property_match_cache[cache_key] if @property_match_cache.key?(cache_key)

        non_unicode_encoding = [Encoding::ASCII_8BIT, Encoding::EUC_JP, Encoding::Windows_31J].include?(encoding)
        incompatible = ascii_property?(name) && (name != "Word" || encoding == Encoding::ASCII_8BIT)
        return @property_match_cache[cache_key] = :incompatible if non_unicode_encoding && incompatible && !character.ascii_only?
        if name == "Word" && non_unicode_encoding && encoding != Encoding::ASCII_8BIT &&
           !character.ascii_only?
          return @property_match_cache[cache_key] = true
        end

        normalized = Onibi::UnicodeProperties.normalize_name(name)
        normalized_character = if name == "Word" && non_unicode_encoding && encoding != Encoding::ASCII_8BIT &&
                                  !character.ascii_only?
                                 character.encode(Encoding::UTF_8)
                               else
                                 character
                               end
        return @property_match_cache[cache_key] = true if Onibi::UnicodeProperties.matches_normalized?(normalized, normalized_character)
        return @property_match_cache[cache_key] = false unless ignorecase && normalized != "ASCII"

        @property_match_cache[cache_key] =
          Onibi::UnicodeProperties.casefold_matches?(normalized, normalized_character)
      rescue EncodingError
        @property_match_cache[cache_key] = false
      end

      def ascii_property?(name)
        %w[ASCII Alpha Alnum Digit Lower Upper Space Word XDigit Blank Cntrl Punct].include?(name)
      end

      def unicode_character(character)
        character.encoding == Encoding::UTF_8 ? character : character.encode(Encoding::UTF_8)
      rescue EncodingError
        character
      end
    end

    # The flat VM has no semantic tree evaluator in its ancestor chain.
    class FlatExecutor < Executor
      private

      def tree_results(*)
        raise "flat VM attempted to enter semantic tree evaluation"
      end
    end

    # Compatibility programs retain the recursive evaluator until their
    # remaining semantic forms are lowered to flat instructions.
    class CompatibilityExecutor < Executor
      include SemanticTreeEvaluator
    end
  end
end
