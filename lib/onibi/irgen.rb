# frozen_string_literal: true

module Onibi
  module IRGen
    module YARVIR
      # rubocop:disable Metrics/ModuleLength
      module SemanticBytecode
        # `casefold` is the compiler-owned folded literal. `casefold_segments`
        # keeps each source character boundary for VM backtracking.
        # `fold_boundary_sensitive` tells the VM that MRI keeps this expanded
        # fold aligned with the following operand during backtracking.
        # `fold_boundary` describes a Unicode fold that has a special
        # operand-boundary rule. The VM consumes this metadata directly.
        Literal = Struct.new(:value, :casefold, :casefold_segments, :fold_boundary_sensitive,
                             :fold_boundary, :fold_prefix_boundary, :fold_policy) do
          def source_width
            value.each_char.count
          end

          def folded_width
            (casefold || value).each_char.count
          end
        end
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
        Assertion = Struct.new(:body, :kind, :widths, :folded_widths, :flat_atoms) do
          def tree_free?
            body.nil? && Array(flat_atoms).flatten.all? do |atom|
              !atom.respond_to?(:body) && !atom.respond_to?(:parts) && !atom.respond_to?(:branches)
            end
          end
        end
        Any = Struct.new(:value)
        Anchor = Struct.new(:kind)
        Sequence = Struct.new(:parts)
        # `operand_context` marks an alternation that is the next operand in
        # a sequence. A root alternation selects a whole branch instead.
        Alternation = Struct.new(:branches, :operand_context, :fold_policy)
        Group = Struct.new(:body, :number, :capture, :name)
        # A capture inside a flat assertion. The body is already lowered to
        # primitive assertion atoms, so the VM does not retain a tree node.
        CaptureAtom = Struct.new(:number, :name, :atoms)
        RepeatAtom = Struct.new(:atoms, :minimum, :maximum, :mode)
        AssertionAtom = Struct.new(:kind, :widths, :flat_atoms)
        ConditionalAtom = Struct.new(:condition, :yes_atoms, :no_atoms)
        OptionGroup = Struct.new(:body, :ignorecase, :multiline, :extended)
        AtomicGroup = Struct.new(:body)
        Conditional = Struct.new(:condition, :yes_branch, :no_branch)
        SubexpressionCall = Struct.new(:identifier, :named)
        Absence = Struct.new(:body, :flat_atoms)
        AbsenceRepeat = Struct.new(:atoms, :minimum)
        AbsenceNullableRepeat = Struct.new(:atom)
        AbsenceNullableCapture = Struct.new(:atom, :number, :name)
        AlternationAtom = Struct.new(:variants)
        AlternationGroupRepeat = Struct.new(:variants, :minimum, :number, :name)
        AbsenceAssertion = Struct.new(:assertion)
        AbsenceProbe = Struct.new(:program, :capture_program, :capture_requires_end)
        # `lazy_exact` records MRI's special `{n}?` form. It accepts zero or
        # exactly `n` repetitions, not the intermediate counts.
        Quantifier = Struct.new(:expression, :kind, :minimum, :maximum, :mode, :lazy_exact)
        ZeroWidthRepeat = Struct.new(:predicate, :minimum, :maximum, :number, :capture, :name)
        NullableGroupRepeat = Struct.new(:body, :kind, :minimum, :maximum, :mode, :lazy_exact,
                                         :number, :name)
        NestedPossessiveRepeat = Struct.new(:body, :kind, :minimum, :maximum, :mode, :lazy_exact)

        # A linear semantic instruction table.  The VM receives this table
        # through the automaton instruction stream, instead of through a
        # separate program flag.
        SemanticInstruction = Struct.new(:opcode, :operand, keyword_init: true) do
          def initialize(opcode:, operand: nil) = super.freeze
        end
        VMInstruction = Struct.new(:opcode, :operand, :target, keyword_init: true) do
          def initialize(opcode:, operand: nil, target: nil) = super.freeze
        end
        FoldBoundary = Struct.new(:operand, :next_pc, :literal, :casefold, :boundary, :policy,
                                  :next_literal, :next_casefold, :next_source_width,
                                  :next_literals,
                                  :next_fold_width_deltas,
                                  :backedge_pcs,
                                  keyword_init: true) do
          def initialize(operand:, next_pc:, literal:, casefold:, boundary:, policy:,
                         next_literal:, next_casefold:, next_source_width:, next_literals:,
                         next_fold_width_deltas:, backedge_pcs:)
            super.freeze
          end

          def expanded_tail?
            boundary&.fetch(:kind, nil) == :expanded_tail
          end

          def tail_matches_next_fold?
            return false unless expanded_tail?

            tail = boundary.fetch(:tail, nil)
            next_fold = next_casefold || next_literal&.value
            tail && next_fold && tail == next_fold
          end

          def tail_matches_any_next_fold?
            return false unless expanded_tail?

            tail = boundary.fetch(:tail, nil)
            tail && next_literals.any? do |literal|
              tail == (literal.casefold || literal.value)
            end
          end

          def matching_next_fold_indices
            return [] unless expanded_tail?

            tail = boundary.fetch(:tail, nil)
            return [] unless tail

            next_literals.each_index.select do |index|
              literal = next_literals[index]
              tail == (literal.casefold || literal.value)
            end
          end

          def matching_next_fold_width?(length)
            matching_next_fold_indices.any? do |index|
              next_literals[index].value.each_char.count == length
            end
          end

          def matching_next_fold_width_delta?(length, delta)
            matching_next_fold_indices.any? do |index|
              next_literals[index].value.each_char.count == length &&
                next_fold_width_deltas[index] == delta
            end
          end

          def repeat_backedge?
            backedge_pcs.any?
          end

          def fold_width_delta
            return 0 unless literal && casefold

            casefold.each_char.count - literal.value.each_char.count
          end

          def next_fold_width_delta
            return 0 unless next_literal && next_casefold

            next_casefold.each_char.count - next_literal.value.each_char.count
          end

          def source_width_match?(length)
            literal && length == literal.source_width
          end

          def next_source_width_match?(length)
            next_literal && length == next_source_width
          end

          def next_fold_width_delta_candidates
            next_fold_width_deltas
          end
        end

        VM_OPCODES = %i[consume fold_boundary consume_class consume_property consume_escape consume_any
                        assert_anchor split jump fail capture_start capture_end repeat
                        repeat_nullable_group repeat_nested_possessive
                        repeat_alternation_group
                        repeat_possessive repeat_zero_width repeat_absence assert conditional backreference call return
                        scope_start scope_end atomic_start atomic_end absence nop accept].freeze
        FlatProgram = Struct.new(:instructions, :entry, :subroutines, :operands, keyword_init: true) do
          def initialize(instructions:, entry: 0, subroutines: {}, operands: [])
            unknown = instructions.map(&:opcode) - VM_OPCODES
            raise ArgumentError, "unknown flat VM opcode: #{unknown.first}" unless unknown.empty?

            limit = instructions.length
            raise ArgumentError, "flat VM entry is invalid: #{entry.inspect}" unless entry.is_a?(Integer) && entry >= 0 && entry < limit

            invalid_pc = instructions.each_with_index.find do |instruction, _index|
              targets = instruction.target.is_a?(Array) ? instruction.target : [instruction.target]
              (%i[jump split].include?(instruction.opcode) || instruction.opcode == :fold_boundary) &&
                (instruction.opcode != :fold_boundary || instruction.target) &&
                targets.any? do |target|
                  !target.is_a?(Integer) || target.negative? || target >= limit ||
                    (instruction.opcode == :fold_boundary && target <= _index)
                end
            end
            raise ArgumentError, "flat VM control-flow target is invalid" if invalid_pc

            invalid_target = subroutines.values.find do |target|
              !target.is_a?(Integer) || target.negative? || target >= limit
            end
            raise ArgumentError, "flat VM subroutine target is invalid: #{invalid_target.inspect}" if invalid_target

            retained = operands.find { |operand| self.class.composite_payload?(operand) }
            raise ArgumentError, "flat VM operand retains a composite payload: #{retained.class}" if retained

            super(instructions: instructions.freeze, entry: entry, subroutines: subroutines.freeze,
                  operands: operands.freeze)
            freeze
          end

          def operand(index)
            operands.fetch(index)
          end

          def call_target(identifier)
            subroutines.fetch(identifier) { subroutines.fetch(identifier.to_s) }
          end

          def instruction_at(program_counter)
            instructions.fetch(program_counter)
          end

          def valid_pc?(program_counter)
            program_counter.is_a?(Integer) && program_counter >= 0 && program_counter < instructions.length
          end

          def opcode_at(program_counter)
            instruction_at(program_counter).opcode
          end

          def boundary_target(program_counter)
            metadata = boundary_metadata(program_counter)
            metadata&.next_pc && instruction_at(metadata.next_pc)
          end

          def boundary_metadata(program_counter)
            instruction = instruction_at(program_counter)
            return nil unless instruction.opcode == :fold_boundary

            literal = instruction.operand.is_a?(Integer) ? operand(instruction.operand) : nil
            next_pc = instruction.target || program_counter + 1
            split_targets = nil
            backedge_pcs = []
            8.times do
              break if next_pc >= instructions.length

              next_instruction = instruction_at(next_pc)
              if next_instruction.opcode == :scope_end
                next_pc += 1
              elsif next_instruction.opcode == :jump && next_instruction.target.is_a?(Integer) &&
                    next_instruction.target > program_counter
                next_pc = next_instruction.target
              elsif next_instruction.opcode == :jump && next_instruction.target.is_a?(Integer)
                backedge_pcs << next_instruction.target
                break
              elsif next_instruction.opcode == :split
                split_targets = Array(next_instruction.target)
                backedge_pcs.concat(split_targets.select { |candidate| candidate.is_a?(Integer) && candidate <= program_counter })
                target = Array(next_instruction.target).find do |candidate|
                  candidate.is_a?(Integer) && candidate > program_counter
                end
                break unless target

                next_pc = target
              else
                break
              end
              break if next_pc >= instructions.length
            end
            next_pc = nil if next_pc >= instructions.length
            next_instruction = next_pc && instruction_at(next_pc)
            next_literal = if next_instruction&.operand.is_a?(Integer) &&
                              %i[consume fold_boundary].include?(next_instruction.opcode)
                             operand(next_instruction.operand)
                           end
            next_literals = if split_targets
                              boundary_candidate_literals(split_targets, program_counter)
                            else
                              [next_literal].compact
                            end
            FoldBoundary.new(operand: instruction.operand, next_pc: next_pc, literal: literal,
                             casefold: literal&.casefold, boundary: literal&.fold_boundary,
                             policy: literal&.fold_policy, next_literal: next_literal,
                             next_casefold: next_literal&.casefold,
                             next_source_width: next_literal&.source_width,
                             next_literals: next_literals,
                             next_fold_width_deltas: next_literals.map do |candidate|
                               next_fold = candidate.casefold
                               next_fold ? next_fold.each_char.count - candidate.value.each_char.count : 0
                             end,
                             backedge_pcs: backedge_pcs.uniq)
          end

          def backedge_targets(program_counter)
            boundary_metadata(program_counter)&.backedge_pcs || []
          end

          def boundary_candidate_literals(starts, origin)
            pending = Array(starts).dup
            visited = {}
            candidates = []
            16.times do
              pc = pending.shift
              next if pc.nil? || visited[pc] || pc <= origin || pc >= instructions.length

              visited[pc] = true
              instruction = instruction_at(pc)
              case instruction.opcode
              when :consume, :fold_boundary
                candidates << operand(instruction.operand) if instruction.operand.is_a?(Integer)
              when :scope_end
                pending << pc + 1
              when :jump
                pending << instruction.target if instruction.target.is_a?(Integer)
              when :split
                pending.concat(Array(instruction.target))
              end
            end
            candidates.uniq
          end

          def tree_free?
            operands.none? { |operand| self.class.composite_payload?(operand) }
          end

          def self.composite_payload?(operand)
            return false if operand.is_a?(NullableGroupRepeat)
            return false if operand.is_a?(NestedPossessiveRepeat)
            return false if operand.is_a?(AlternationGroupRepeat)
            if operand.is_a?(AlternationAtom)
              return operand.variants.flatten.any? { |item| composite_payload?(item) }
            end
            return true if operand.is_a?(Assertion) && !operand.tree_free?
            return true if operand.respond_to?(:body) && operand.body
            return true if operand.respond_to?(:parts) && operand.parts.any?
            return true if operand.respond_to?(:branches) && operand.branches.any?

            false
          end
        end
        SemanticProgram = Struct.new(:instructions, :entry, :subexpressions, keyword_init: true) do
          def initialize(instructions:, entry:, subexpressions: {})
            super(instructions: instructions.freeze, entry: entry, subexpressions: subexpressions.freeze)
            @vm_instructions = instructions.each_index.map do |index|
              VMInstruction.new(opcode: vm_opcode(instructions.fetch(index).opcode), operand: index)
            end.freeze
            @flat_program = FlatCompiler.new(self).compile
            freeze
          end

          def entry_node
            materialize(entry, {})
          end

          def materialized_node(index)
            materialize(index, {})
          end

          # Return the executable command stream. Each command has an integer
          # operand that points into the immutable semantic table. The VM can
          # dispatch commands without inspecting AST classes.
          def vm_instructions
            @vm_instructions
          end

          def flat_program
            @flat_program
          end

          private

          def vm_opcode(type)
            {
              Literal => :consume,
              CharacterClass => :consume_class,
              Property => :consume_property,
              Escape => :consume_escape,
              Any => :consume_any,
              Anchor => :assert_anchor,
              Group => :capture,
              OptionGroup => :scope_flags,
              AtomicGroup => :atomic,
              Sequence => :sequence,
              Alternation => :choice,
              Quantifier => :repeat,
              Assertion => :assert,
              Backreference => :backreference,
              Conditional => :conditional,
              SubexpressionCall => :call,
              Absence => :absence
            }.fetch(type, :semantic)
          end

          def materialize(index, cache)
            return cache[index] if cache.key?(index)

            instruction = instructions.fetch(index)
            fields = instruction.operand.map { |field| decode(field, cache) }
            node = instruction.opcode.new(*fields)
            cache[index] = node
            node
          end

          def decode(value, cache)
            return materialize(value[1], cache) if value.is_a?(Array) && value.first == :__semantic_ref
            return value.drop(1).map { |item| decode(item, cache) } if value.is_a?(Array) && value.first == :__semantic_array
            return value.drop(1).each_slice(2).to_h { |key, item| [key, decode(item, cache)] } if value.is_a?(Array) && value.first == :__semantic_hash

            value
          end
        end

        # Compile the common semantic subset to real PC-based control flow.
        # Unsupported Unicode and lookaround forms use the compatibility path.
        class FlatCompiler
          LEAF_TYPES = [Literal, CharacterClass, Property, Escape, Any, Anchor].freeze

          def initialize(program)
            @program = program
            @nodes = {}
            @subexpressions = program.subexpressions
            @visiting = {}.compare_by_identity
            @depth = 0
            @code = []
          end

          def compile
            return unless supported?(@program.entry_node)

            entry = emit(@program.entry_node)
            @code << VMInstruction.new(opcode: :accept)
            subroutines = {}
            @subexpressions.each do |identifier, body|
              next if subroutines.key?(identifier)

              subroutines[identifier] = @code.length
              emit(body)
              @code << VMInstruction.new(opcode: :return)
            end
            operands = @program.instructions.each_index.map do |index|
              flat_operand(@program.materialized_node(index))
            end
            FlatProgram.new(instructions: @code, entry: entry, subroutines: subroutines,
                            operands: operands)
          end

          private

          # Keep only fields that the flat dispatcher needs. Composite bodies
          # stay in the semantic table for compatibility execution, but the
          # flat VM receives metadata and primitive atom lists only.
          def flat_operand(node)
            case node
            when Assertion
              Assertion.new(nil, node.kind, node.widths, node.folded_widths, node.flat_atoms)
            when Absence
              body = unwrap_single_sequence(node.body)
              if body.is_a?(Group) && body.capture
                repeated = unwrap_single_sequence(body.body)
                if repeated.is_a?(Quantifier) && repeated.minimum > 1 && repeated.maximum.nil? &&
                   repeated.expression.is_a?(Group) && repeated.expression.capture
                  alternation = unwrap_single_sequence(repeated.expression.body)
                  if alternation.is_a?(Alternation) && alternation.branches.all? do |branch|
                    branch.is_a?(Sequence) && branch.parts.one? && branch.parts.first.is_a?(Literal) &&
                      branch.parts.first.casefold.nil?
                  end
                    variants = alternation.branches.map(&:parts)
                    return AbsenceRepeat.new([AlternationAtom.new(variants)], repeated.minimum)
                  end
                end
              end
              if body.is_a?(Quantifier) && body.minimum.positive? && body.maximum.nil? &&
                 body.expression.is_a?(Group) && body.expression.capture
                inner_group = unwrap_single_sequence(body.expression.body)
                if body.minimum > 1 && inner_group.is_a?(Group) && inner_group.capture
                  alternation = unwrap_single_sequence(inner_group.body)
                  if alternation.is_a?(Alternation) && alternation.branches.all? do |branch|
                    branch.is_a?(Sequence) && branch.parts.one? && branch.parts.first.is_a?(Literal) &&
                      branch.parts.first.casefold.nil?
                  end
                    variants = alternation.branches.map(&:parts)
                    return AbsenceRepeat.new([AlternationAtom.new(variants)], body.minimum)
                  end
                end
                alternation = unwrap_single_sequence(body.expression.body)
                if alternation.is_a?(Alternation) && alternation.branches.all? do |branch|
                  branch.is_a?(Sequence) && branch.parts.one? && branch.parts.first.is_a?(Literal) &&
                    branch.parts.first.casefold.nil?
                end
                  variants = alternation.branches.map { |branch| branch.parts }
                  return AbsenceRepeat.new([AlternationAtom.new(variants)], body.minimum)
                end
              end
              if body.is_a?(Quantifier) && body.minimum.positive? && body.maximum.nil? &&
                 body.expression.is_a?(Group) && body.expression.capture
                atoms = absence_repeat_atoms(body.expression.body)
                return AbsenceRepeat.new(atoms, body.minimum) if atoms&.all? do |item|
                  item.is_a?(Literal) || item.is_a?(CharacterClass) || item.is_a?(Property) ||
                    item.is_a?(Escape) || item.is_a?(Any)
                end
              end
              if body.is_a?(Group) && body.capture
                atom = unwrap_single_sequence(body.body)
                if atom.is_a?(Quantifier) && atom.minimum.zero? && atom.maximum == 1 &&
                   atom.expression.is_a?(Literal) && atom.expression.casefold.nil?
                  return AbsenceNullableCapture.new(atom.expression, body.number, body.name)
                end
              end
              probe = absence_probe_program(node)
              return AbsenceProbe.new(*probe) if probe

              assertion = absence_assertion(node)
              return AbsenceAssertion.new(assertion) if assertion

              if body.is_a?(Quantifier) && body.minimum.zero? && body.maximum.nil?
                atom = absence_repeat_atoms(body.expression)
                return AbsenceNullableRepeat.new(atom.first) if atom&.length == 1
              end

              if body.is_a?(Quantifier) && body.minimum.positive? && body.maximum.nil? &&
                 (body.expression.is_a?(Literal) || body.expression.is_a?(CharacterClass) ||
                  body.expression.is_a?(Property) ||
                  body.expression.is_a?(Escape) ||
                  body.expression.is_a?(Any) ||
                  body.expression.is_a?(Group))
                atoms = absence_repeat_atoms(body.expression)
                return AbsenceRepeat.new(atoms, body.minimum) if atoms&.all? do |atom|
                  atom.is_a?(Literal) || atom.is_a?(CharacterClass) ||
                  atom.is_a?(Property) || atom.is_a?(Escape) ||
                  atom.is_a?(Any)
                end
              end
              Absence.new(nil, node.flat_atoms)
            when OptionGroup
              OptionGroup.new(nil, node.ignorecase, node.multiline, node.extended)
            when Group
              Group.new(nil, node.number, node.capture, node.name)
            when AtomicGroup
              AtomicGroup.new(nil)
            when Conditional
              Conditional.new(node.condition, nil, nil)
            when Sequence
              Sequence.new([])
            when Alternation
              Alternation.new([])
            when Quantifier
              if alternation_group_repeat?(node)
                group = node.expression
                body = unwrap_single_sequence(group.body)
                variants = body.branches.map { |branch| flat_operand(unwrap_single_sequence(branch)) }
                return AlternationGroupRepeat.new(variants, node.minimum, group.number, group.name)
              end
              if node.mode == :possessive && node.maximum.nil? && node.expression.is_a?(Quantifier) &&
                 node.expression.maximum && node.expression.maximum <= 32 &&
                 [Literal, Any, CharacterClass, Escape, Property].any? { |type| node.expression.expression.is_a?(type) }
                return NestedPossessiveRepeat.new(
                  flat_operand(node.expression), node.kind, node.minimum, node.maximum,
                  node.mode, node.lazy_exact
                )
              end
              if nullable_group_repeat?(node)
                body = unwrap_single_sequence(node.expression.body)
                return NullableGroupRepeat.new(
                  flat_operand(body), node.kind, node.minimum, node.maximum, node.mode,
                  node.lazy_exact, node.expression.capture ? node.expression.number : nil,
                  node.expression.capture ? node.expression.name : nil
                )
              end
              if zero_width_repeat?(node)
                expression = node.expression
                body = expression.is_a?(Group) ? expression.body : expression
                body = body.parts.first if body.is_a?(Sequence) && body.parts.one?
                return ZeroWidthRepeat.new(body, node.minimum, node.maximum,
                                           expression.is_a?(Group) ? expression.number : nil,
                                           expression.is_a?(Group) && expression.capture,
                                           expression.is_a?(Group) ? expression.name : nil)
              end
              expression = node.expression.is_a?(Group) ? nil : node.expression
              Quantifier.new(expression, node.kind, node.minimum, node.maximum, node.mode, node.lazy_exact)
            else
              node
            end
          end

          def supported?(node)
            return false if @depth >= 64

            @depth += 1
            if @visiting[node]
              @depth -= 1
              return false
            end

            @visiting[node] = true
            result = supported_node?(node)
            @visiting.delete(node)
            @depth -= 1
            result
          end

          def supported_node?(node)
            if node.is_a?(Literal)
              return node.casefold.nil? || full_fold_literal?(node) || ascii_casefold_safe_literal?(node) ||
                     Onibi::IRGen::YARVIR.semantic_simple_casefold_safe?(node)
            end
            return flat_character_class_safe?(node) if node.is_a?(CharacterClass)
            return true if node.is_a?(Any)
            return true if node.is_a?(Anchor)
            if node.is_a?(Escape)
              return %i[digit non_digit not_digit word not_word space not_space horizontal_space
                        not_horizontal_space linebreak grapheme word_boundary not_word_boundary start_match match_reset].include?(node.kind)
            end
            return flat_property_safe?(node) if node.is_a?(Property)
            return true if node.is_a?(Backreference)

            if node.is_a?(Assertion)
              body = unwrap_single_sequence(node.body)
              return %i[positive positive_lookahead negative negative_lookahead
                        positive_lookbehind negative_lookbehind].include?(node.kind) &&
                     node.flat_atoms &&
                     (supported?(body) || SemanticBytecode.flat_assertion_atoms(body, capture: true))
            end
            if node.is_a?(Conditional)
              condition = node.condition.is_a?(Array) ? node.condition.first : node.condition
              return (condition.is_a?(Integer) || condition.is_a?(String)) &&
                     supported?(node.yes_branch) &&
                     (!node.no_branch || supported?(node.no_branch))
            end
            if node.is_a?(SubexpressionCall)
              body = subexpression_body(node)
              return true if body && @visiting[body]

              return body && supported?(body)
            end
            return node.parts.all? { |part| supported?(part) } if node.is_a?(Sequence)
            return node.branches.all? { |branch| supported?(branch) } if node.is_a?(Alternation)
            return supported?(node.body) if node.is_a?(Group) && (!node.capture || node.number)

            if node.is_a?(OptionGroup)
              return false if node.ignorecase && !scoped_casefold_safe?(node.body)

              return supported?(node.body)
            end
            return supported?(node.body) if node.is_a?(AtomicGroup)
            return absence_flat_safe?(node) if node.is_a?(Absence)

            if node.is_a?(Quantifier)
              atom = node.expression
              return true if alternation_group_repeat?(node)
              return true if node.mode == :possessive && node.maximum.nil? && atom.is_a?(Quantifier) &&
                             atom.maximum && atom.maximum <= 32 &&
                             [Literal, Any, CharacterClass, Escape, Property].any? { |type| atom.expression.is_a?(type) } &&
                             (!atom.expression.is_a?(Escape) || !%i[word_boundary not_word_boundary].include?(atom.expression.kind)) &&
                             supported?(atom)
              return true if nullable_group_repeat?(node)
              if atom.is_a?(Group) && nested_nullable_group_repeat?(node)
                return true
              end
              return true if atom.is_a?(Anchor) && zero_width_repeat?(node)
              if (atom.is_a?(Group) || atom.is_a?(Assertion) || atom.is_a?(Escape)) && (repeatable_group?(node) || possessive_group_loop?(node) ||
                               possessive_group?(node) || zero_width_repeat?(node))
                return true
              end
              return false if atom.is_a?(Escape) && %i[word_boundary not_word_boundary].include?(atom.kind)
              return false unless [Literal, CharacterClass, Any, Escape, Property, Backreference,
                                   OptionGroup, Absence].include?(atom.class) && supported?(atom)

              return node.maximum.nil? || node.maximum <= 32 ||
                     (atom.is_a?(Literal) && node.maximum.positive?)
            end
            false
          end

          def index_for(node)
            @nodes[node] ||= @program.instructions.each_index.find do |index|
              @program.materialized_node(index) == node
            end
          end

          def emit(node)
            case node
            when Sequence
              return emit_command(:nop, index_for(node), nil) if node.parts.empty?

              first = nil
              starts = []
              node.parts.each do |part|
                pc = emit(part)
                first ||= pc
                starts << pc
              end
              starts.each_with_index do |pc, index|
                next unless @code[pc]&.opcode == :fold_boundary

                @code[pc] = VMInstruction.new(opcode: :fold_boundary,
                                              operand: @code[pc].operand,
                                              target: starts[index + 1])
              end
              first
            when Alternation
              return emit(node.branches.first) if node.branches.one?

              split = @code.length
              @code << VMInstruction.new(opcode: :split, target: [])
              starts = []
              jumps = []
              node.branches.each_with_index do |branch, index|
                starts << @code.length
                emit(branch)
                jumps << emit_command(:jump, nil, nil) unless index == node.branches.length - 1
              end
              join = @code.length
              jumps.each { |jump| @code[jump] = VMInstruction.new(opcode: :jump, target: join) }
              @code[split] = VMInstruction.new(opcode: :split, target: starts.freeze)
              split
            when Group
              start = node.capture ? emit_command(:capture_start, index_for(node), node.number) : nil
              body = emit(node.body)
              emit_command(:capture_end, index_for(node), [node.number, node.name].freeze) if node.capture
              start || body
            when OptionGroup
              start = emit_command(:scope_start, index_for(node), nil)
              emit(node.body)
              emit_command(:scope_end, index_for(node), nil)
              start
            when AtomicGroup
              start = emit_command(:atomic_start, index_for(node), nil)
              emit(node.body)
              emit_command(:atomic_end, index_for(node), nil)
              start
            when Conditional
              branch = @code.length
              @code << VMInstruction.new(opcode: :conditional, operand: index_for(node), target: [])
              yes_start = @code.length
              emit(node.yes_branch)
              yes_jump = emit_command(:jump, nil, nil)
              no_start = @code.length
              if node.no_branch
                emit(node.no_branch)
              else
                emit_command(:nop, index_for(node), nil)
              end
              join = @code.length
              @code[yes_jump] = VMInstruction.new(opcode: :jump, target: join)
              @code[branch] = VMInstruction.new(opcode: :conditional, operand: index_for(node),
                                                target: [yes_start, no_start].freeze)
              branch
            when SubexpressionCall
              emit_command(:call, node.identifier, nil)
            when Quantifier
              if alternation_group_repeat?(node)
                emit_command(:repeat_alternation_group, index_for(node), nil)
              elsif node.mode == :possessive && node.maximum.nil? && node.expression.is_a?(Quantifier) &&
                 node.expression.maximum && node.expression.maximum <= 32 &&
                 [Literal, Any, CharacterClass, Escape, Property].any? { |type| node.expression.expression.is_a?(type) }
                emit_command(:repeat_nested_possessive, index_for(node), nil)
              elsif nullable_group_repeat?(node)
                emit_command(:repeat_nullable_group, index_for(node), nil)
              elsif node.expression.is_a?(Group) && (repeatable_group?(node) || nested_nullable_group_repeat?(node))
                emit_group_quantifier(node)
              elsif zero_width_repeat?(node)
                emit_command(:repeat_zero_width, index_for(node), nil)
              elsif node.expression.is_a?(Group) && possessive_group_loop?(node)
                emit_possessive_group_quantifier(node)
              elsif node.expression.is_a?(Group) && possessive_group?(node)
                emit_command(:repeat_possessive, index_for(node), nil)
              elsif scoped_optional_choice?(node)
                emit_scoped_optional_choice(node)
              elsif repeatable_option_group?(node)
                emit_group_quantifier(node)
              elsif node.expression.is_a?(Absence) && absence_flat_safe?(node.expression)
                emit_command(:repeat_absence, index_for(node), nil)
              else
                emit_command(:repeat, index_for(node), nil)
              end
            else
              emit_leaf(node)
            end
          end

          def emit_fixed(node)
            first = nil
            node.minimum.times do
              pc = emit(node.expression)
              first ||= pc
            end
            first || emit_command(:nop, index_for(node), nil)
          end

          def emit_group_quantifier(node)
            first = emit_fixed(node)
            if node.maximum.nil?
              loop_start = @code.length
              split = @code.length
              @code << VMInstruction.new(opcode: :split, target: [])
              body_start = @code.length
              emit(node.expression)
              emit_command(:jump, nil, loop_start)
              exit_pc = @code.length
              targets = node.mode == :lazy ? [exit_pc, body_start] : [body_start, exit_pc]
              @code[split] = VMInstruction.new(opcode: :split, target: targets.freeze)
            else
              (node.maximum - node.minimum).times do
                split = @code.length
                @code << VMInstruction.new(opcode: :split, target: [])
                body_start = @code.length
                emit(node.expression)
                exit_pc = @code.length
                targets = node.mode == :lazy ? [exit_pc, body_start] : [body_start, exit_pc]
                @code[split] = VMInstruction.new(opcode: :split, target: targets.freeze)
              end
            end
            first
          end

          def emit_leaf(node)
            opcode = case node
                     when Literal then node.fold_boundary_sensitive ? :fold_boundary : :consume
                     when CharacterClass then :consume_class
                     when Property then :consume_property
                     when Escape then :consume_escape
                     when Any then :consume_any
                     when Anchor then :assert_anchor
                     when Backreference then :backreference
                     when Assertion then :assert
                     when Absence then :absence
                     else :consume
                     end
            emit_command(opcode, index_for(node), nil)
          end

          def atomic_safe?(node)
            case node
            when Literal, Any
              true
            when Sequence
              node.parts.all? { |part| atomic_safe?(part) }
            else
              false
            end
          end

          def repeatable_group?(node)
            return false unless node.expression.is_a?(Group)
            return false if node.lazy_exact
            return false if node.maximum && node.maximum > 32
            return false unless node.maximum.nil? || node.maximum >= node.minimum
            return false unless %i[greedy lazy].include?(node.mode)

            if node.minimum.zero? && node.maximum == 1
              body = node.expression.body
              body = body.parts.first if body.is_a?(Sequence) && body.parts.one?
              return true if body.is_a?(Quantifier) && body.minimum.zero? && body.maximum == 1 &&
                             body.expression.is_a?(Literal)
            end

            repeatable_body?(node.expression.body) && supported?(node.expression)
          end

          def nested_nullable_group_repeat?(node)
            return false unless node.expression.is_a?(Group)
            return false unless node.maximum && node.maximum <= 32 && node.maximum >= node.minimum

            body = node.expression.body
            body = body.parts.first if body.is_a?(Sequence) && body.parts.one?
            body.is_a?(Quantifier) && body.minimum.zero? && body.maximum == 1 && supported?(body)
          end

          def nullable_group_repeat?(node)
            return false unless node.expression.is_a?(Group) && node.maximum.nil?

            body = node.expression.body
            body = body.parts.first if body.is_a?(Sequence) && body.parts.one?
            body.is_a?(Quantifier) && body.minimum.zero? && (body.maximum == 1 || body.maximum.nil?) &&
              %i[greedy lazy].include?(body.mode) && supported?(body)
          end

          def alternation_group_repeat?(node)
            return false unless node.is_a?(Quantifier) && node.maximum.nil? && node.mode == :greedy
            return false unless node.expression.is_a?(Group) && node.expression.capture

            body = unwrap_single_sequence(node.expression.body)
            body.is_a?(Alternation) && body.branches.all? do |branch|
              atom = unwrap_single_sequence(branch)
              atom.is_a?(Anchor) || atom.is_a?(Literal)
            end
          end

          def repeatable_option_group?(node)
            return false unless node.expression.is_a?(OptionGroup)
            return false if node.lazy_exact
            return false if node.maximum && node.maximum > 32
            return false unless node.maximum.nil? || node.maximum >= node.minimum
            return false unless %i[greedy lazy].include?(node.mode)

            repeatable_body?(node.expression.body) && supported?(node.expression)
          end

          def zero_width_repeat?(node)
            return false unless node.expression.is_a?(Group) || node.expression.is_a?(Assertion) ||
                                node.expression.is_a?(Escape) || node.expression.is_a?(Anchor)
            return false if node.maximum && node.maximum > 32
            return false if node.maximum.nil? && node.minimum > 1
            return false if node.maximum && node.maximum < node.minimum

            body = node.expression.is_a?(Group) ? node.expression.body : node.expression
            body = body.parts.first if body.is_a?(Sequence) && body.parts.one?
            body.is_a?(Anchor) || body.is_a?(Assertion) ||
              (body.is_a?(Escape) && %i[word_boundary not_word_boundary].include?(body.kind))
          end

          def possessive_group?(node)
            return false unless node.expression.is_a?(Group) && node.mode == :possessive
            return false if node.maximum && node.maximum > 32

            group = node.expression
            group.capture && literal_body?(group.body) &&
              !nested_capture?(group.body) && supported?(group)
          end

          def possessive_group_loop?(node)
            return false unless node.expression.is_a?(Group) && node.mode == :possessive
            return false if node.maximum && node.maximum > 32
            return false unless node.maximum.nil? || node.maximum >= node.minimum

            repeatable_body?(node.expression.body) && supported?(node.expression)
          end

          def emit_possessive_group_quantifier(node)
            start = emit_command(:atomic_start, index_for(node), nil)
            emit_group_quantifier(node)
            emit_command(:atomic_end, index_for(node), nil)
            start
          end

          def scoped_optional_choice?(node)
            node.expression.is_a?(OptionGroup) && node.minimum.zero? && node.maximum == 1 &&
              !node.lazy_exact && %i[greedy lazy].include?(node.mode)
          end

          def emit_scoped_optional_choice(node)
            split = @code.length
            @code << VMInstruction.new(opcode: :split, target: [])
            body_start = @code.length
            emit(node.expression)
            join = @code.length
            targets = node.mode == :lazy ? [join, body_start] : [body_start, join]
            @code[split] = VMInstruction.new(opcode: :split, target: targets.freeze)
            split
          end

          def nested_capture?(node)
            return node.capture if node.is_a?(Group)
            return node.parts.any? { |part| nested_capture?(part) } if node.is_a?(Sequence)

            false
          end

          def scoped_casefold_safe?(node)
            case node
            when Literal
              return true if node.value.ascii_only? && SemanticBytecode.multi_char_casefold_source?(node.value)

              unless node.value.ascii_only?
                folded = node.value.downcase(:fold)
                return true if full_fold_literal?(node)

                return node.value.each_char.one? && folded.each_char.one? &&
                       Onibi::UnicodeProperties.reverse_casefold_variants(folded).all? do |variant|
                         variant.each_char.one?
                       end
              end
              return false unless node.value.each_char.one?

              folded = node.value.downcase(:fold)
              Onibi::UnicodeProperties.reverse_casefold_variants(folded).all? do |variant|
                variant.ascii_only? && variant.each_char.one?
              end
            when Sequence
              return false if node.parts.length > 1 && node.parts.any? do |part|
                part.is_a?(Literal) && !part.value.ascii_only? &&
                  (part.fold_boundary_sensitive ||
                   Onibi::UnicodeProperties.reverse_casefold_variants(part.casefold.to_s).any?)
              end

              node.parts.all? { |part| scoped_casefold_safe?(part) }
            when Alternation
              node.branches.all? { |branch| scoped_casefold_safe?(branch) }
            when CharacterClass
              return true if node.casefolds.length == 1 &&
                             node.casefolds.all? { |_source, folded| folded.each_char.count == 2 }

              node.casefolds.empty? &&
                node.folded_characters.all? { |character| character.each_char.count == 1 } &&
                node.fold_boundaries.values.compact.all? do |boundary|
                  boundary[:kind] == :simple_fold_source
                end
            when Property
              fold_invariant_property?(node) ||
                Onibi::UnicodeProperties::PROPERTY_MATCHERS.key?(
                  Onibi::UnicodeProperties.normalize_name(node.name.to_s)
                )
            when Any
              true
            when Backreference
              true
            when Conditional
              true
            when Absence
              Array(node.flat_atoms).flatten.all? do |atom|
                (atom.is_a?(Literal) && atom.value.ascii_only?) ||
                  (atom.is_a?(Property) && Onibi::UnicodeProperties::PROPERTY_MATCHERS.key?(
                    Onibi::UnicodeProperties.normalize_name(atom.name.to_s)
                  ))
              end
            when Assertion
              %i[positive positive_lookahead negative negative_lookahead
                 positive_lookbehind negative_lookbehind].include?(node.kind) &&
                Array(node.flat_atoms).flatten.all? do |atom|
                atom.is_a?(Any) || (atom.is_a?(Literal) &&
                  (atom.value.ascii_only? ||
                   (atom.value.each_char.one? && atom.casefold.to_s.each_char.one? &&
                    !atom.fold_boundary_sensitive &&
                    Onibi::UnicodeProperties.reverse_casefold_variants(atom.casefold).all? do |variant|
                      variant.each_char.one?
                    end)))
              end
            when Escape
              %i[digit non_digit not_digit word not_word space not_space horizontal_space
                 not_horizontal_space linebreak grapheme word_boundary not_word_boundary].include?(node.kind)
            when Group, AtomicGroup, OptionGroup
              scoped_casefold_safe?(node.body)
            when Quantifier
              scoped_casefold_safe?(node.expression)
            else
              false
            end
          end

          def fold_invariant_property?(node)
            node.casefolds.empty?
          rescue RegexpError, KeyError
            false
          end

          def literal_body?(node)
            case node
            when Literal
              node.casefold.nil?
            when Sequence
              !node.parts.empty? && node.parts.all? { |part| literal_body?(part) }
            else
              false
            end
          end

          def repeatable_body?(node)
            case node
            when Literal, CharacterClass, Any, Property
              true
            when Escape
              !%i[word_boundary not_word_boundary].include?(node.kind)
            when Sequence
              !node.parts.empty? && node.parts.all? { |part| repeatable_body?(part) }
            when Alternation
              !node.branches.empty? && node.branches.all? { |branch| repeatable_body?(branch) }
            when Group
              repeatable_body?(node.body)
            else
              false
            end
          end

          def flat_character_class_safe?(_node)
            true
          end

          def flat_property_safe?(node)
            normalized = Onibi::UnicodeProperties.normalize_name(node.name.to_s)
            Onibi::UnicodeProperties::PROPERTY_MATCHERS.key?(normalized) ||
              (normalized.start_with?("In") &&
               Onibi::UnicodeProperties::BLOCK_LOOKUP.key?(normalized.delete_prefix("In")))
          rescue RegexpError, KeyError
            false
          end

          def ascii_casefold_safe_literal?(node)
            return true if node.casefold.nil?

            node.value.ascii_only? && node.casefold.to_s.ascii_only? &&
              node.casefold.length == node.value.length
          end

          def full_fold_literal?(node)
            node.value.each_char.count == 1 && node.casefold.to_s.each_char.count > 1
          end

          def absence_flat_safe?(node)
            body = unwrap_single_sequence(node.body)
            if body.is_a?(Group) && body.capture
              repeated = unwrap_single_sequence(body.body)
              if repeated.is_a?(Quantifier) && repeated.minimum > 1 && repeated.maximum.nil? &&
                 repeated.expression.is_a?(Group) && repeated.expression.capture
                alternation = unwrap_single_sequence(repeated.expression.body)
                return true if alternation.is_a?(Alternation) && alternation.branches.all? do |branch|
                  branch.is_a?(Sequence) && branch.parts.one? && branch.parts.first.is_a?(Literal) &&
                    branch.parts.first.casefold.nil?
                end
              end
            end
            if body.is_a?(Quantifier) && body.minimum.positive? && body.maximum.nil? &&
               body.expression.is_a?(Group) && body.expression.capture
              inner_group = unwrap_single_sequence(body.expression.body)
              if body.minimum > 1 && inner_group.is_a?(Group) && inner_group.capture
                alternation = unwrap_single_sequence(inner_group.body)
                return true if alternation.is_a?(Alternation) && alternation.branches.all? do |branch|
                  branch.is_a?(Sequence) && branch.parts.one? && branch.parts.first.is_a?(Literal) &&
                    branch.parts.first.casefold.nil?
                end
              end
              alternation = unwrap_single_sequence(body.expression.body)
              return true if alternation.is_a?(Alternation) && alternation.branches.all? do |branch|
                branch.is_a?(Sequence) && branch.parts.one? && branch.parts.first.is_a?(Literal) &&
                  branch.parts.first.casefold.nil?
              end
            end
            if body.is_a?(Quantifier) && body.minimum.positive? && body.maximum.nil? &&
               body.expression.is_a?(Group) && body.expression.capture
              atoms = absence_repeat_atoms(body.expression.body)
              return true if atoms&.all? do |item|
                item.is_a?(Literal) || item.is_a?(CharacterClass) || item.is_a?(Property) ||
                  item.is_a?(Escape) || item.is_a?(Any)
              end
            end
            if body.is_a?(Group) && body.capture
              atom = unwrap_single_sequence(body.body)
              return true if atom.is_a?(Quantifier) && atom.minimum.zero? && atom.maximum == 1 &&
                              atom.expression.is_a?(Literal) && atom.expression.casefold.nil?
            end
            return true if absence_probe_program(node)
            return true if absence_assertion(node)

            return true if body.is_a?(Sequence) && body.parts.empty?

            if body.is_a?(Quantifier) && body.minimum.zero? && body.maximum.nil?
              atom = absence_repeat_atoms(body.expression)
              return true if atom&.length == 1
            end

            return false if node.flat_atoms&.flatten&.any? { |atom| atom.is_a?(CaptureAtom) } &&
                            !simple_capture_absence?(node)

            if body.is_a?(Quantifier) && body.minimum.positive? && body.maximum.nil? && (body.expression.is_a?(Literal) || body.expression.is_a?(CharacterClass) ||
                             body.expression.is_a?(Property) ||
                             body.expression.is_a?(Escape) ||
                             body.expression.is_a?(Any) ||
                             (body.expression.is_a?(Group) && absence_repeat_atoms(body.expression)))
              return true
            end

            node.flat_atoms && flat_atoms_consuming?(node.flat_atoms) && supported?(node.body)
          end

          def absence_probe_program(node)
            body = unwrap_single_sequence(node.body)
            return unless body.is_a?(Group) && !body.capture

            parts = body.body
            return unless parts.is_a?(Sequence) && parts.parts.length > 1

            prefix = parts.parts.first
            suffix = parts.parts.drop(1)
            return unless prefix.is_a?(Quantifier) && prefix.minimum.zero? && prefix.maximum.nil? &&
                          prefix.expression.is_a?(Any)
            capture_indices = suffix.each_index.select do |index|
              suffix[index].is_a?(Group) && suffix[index].capture
            end
            capture_program = nil
            capture_requires_end = false
            unless capture_indices.empty?
              return unless capture_indices.length == 1
              last_capture_index = capture_indices.last
              return unless suffix.each_index.all? do |index|
                capture_indices.include?(index) ||
                  (index > last_capture_index && suffix[index].is_a?(Literal) && suffix[index].casefold.nil?)
              end
              return unless capture_indices.each.all? do |index|
                capture_absence_atom_safe?(unwrap_single_sequence(suffix[index].body))
              end

              capture_requires_end = capture_indices.any? do |index|
                unwrap_single_sequence(suffix[index].body).is_a?(Alternation)
              end
              capture_body = Sequence.new(parts.parts.take(last_capture_index + 2))
              capture_program = SemanticBytecode.lower(capture_body).flat_program
            end
            return unless suffix.all? { |part| wildcard_absence_suffix?(part) }

            [SemanticBytecode.lower(node.body).flat_program, capture_program, capture_requires_end]
          end

          def absence_assertion(node)
            body = unwrap_single_sequence(node.body)
            assertion = if body.is_a?(Group) && !body.capture
                          unwrap_single_sequence(body.body)
                        else
                          body
                        end
            return unless assertion.is_a?(Assertion) && %i[negative negative_lookahead].include?(assertion.kind)

            assertion.flat_atoms ? assertion : nil
          end

          def wildcard_absence_suffix?(node)
            case node
            when Literal
              node.casefold.nil?
            when CharacterClass
              node.casefolds.empty?
            when Property
              node.casefolds.empty?
            when Escape
              %i[digit non_digit not_digit word not_word space not_space horizontal_space
                 not_horizontal_space linebreak grapheme].include?(node.kind)
            when Any
              true
            when Group
              if node.capture
                capture_absence_atom_safe?(unwrap_single_sequence(node.body))
              else
                wildcard_absence_suffix?(node.body)
              end
            when Sequence
              !node.parts.empty? && node.parts.all? { |part| wildcard_absence_suffix?(part) }
            when Alternation
              !node.branches.empty? && node.branches.all? { |branch| wildcard_absence_suffix?(branch) }
            when Quantifier
              node.minimum.positive? && (node.maximum.nil? || node.maximum.positive?) &&
                wildcard_absence_suffix?(node.expression)
            else
              false
            end
          end

          def simple_capture_absence?(node)
            body = unwrap_single_sequence(node.body)
            return false unless body.is_a?(Group) && body.capture

            atom = body.body
            atom = atom.parts.first if atom.is_a?(Sequence) && atom.parts.one?
            return false unless capture_absence_atom_safe?(atom)
            return true unless atom.is_a?(Alternation)

            atom.branches.all? { |branch| branch.parts.one? }
          end

          def capture_absence_atom_safe?(node)
            return node.is_a?(Literal) && node.casefold.nil? if node.is_a?(Literal)
            return false unless node.is_a?(Alternation)

            node.branches.all? do |branch|
              branch.is_a?(Sequence) && branch.parts.all? do |part|
                part.is_a?(Literal) && part.casefold.nil?
              end && branch.parts.any?
            end
          end

          def absence_repeat_atoms(node)
            case node
            when Literal
              node.casefold.nil? ? [node] : nil
            when CharacterClass
              node.casefolds.empty? ? [node] : nil
            when Property
              node.casefolds.empty? ? [node] : nil
            when Escape
              if %i[digit non_digit not_digit word not_word space not_space horizontal_space
                    not_horizontal_space linebreak grapheme].include?(node.kind)
                [node]
              end
            when Any
              [node]
            when Group
              node.capture ? nil : absence_repeat_atoms(node.body)
            when Sequence
              parts = node.parts.map { |part| absence_repeat_atoms(part) }
              parts.all? ? parts.flatten : nil
            end
          end

          def flat_atoms_consuming?(atoms)
            variants = atoms.first.is_a?(Array) ? atoms : [atoms]
            variants.all? do |variant|
              !variant.empty? && variant.all? do |atom|
                if atom.is_a?(Escape)
                  !%i[word_boundary not_word_boundary start_match].include?(atom.kind)
                else
                  !atom.is_a?(Anchor)
                end
              end
            end
          end

          def supported_literal_absence?(node)
            delimiters = literal_delimiters(node)
            delimiters && !delimiters.empty?
          end

          def literal_delimiters(node)
            case node
            when Literal
              return [node.value] if node.casefold.nil? && !node.value.empty?
            when Sequence
              value = node.parts.map { |part| literal_delimiters(part) }
              return [value.flatten.join] if value.all? { |items| items&.one? }
            when Alternation
              values = node.branches.map { |branch| literal_delimiters(branch) }
              return values.flatten if values.all? && values.all? { |items| items&.one? }
            end
            nil
          end

          def assertion_flat_body?(body)
            body = unwrap_single_sequence(body)
            return true if [Literal, CharacterClass, Any].include?(body.class)
            return body.parts.all? { |part| part.is_a?(Literal) && part.casefold.nil? } if body.is_a?(Sequence)
            return body.branches.all? { |branch| literal_body?(branch) } if body.is_a?(Alternation)

            false
          end

          def unwrap_single_sequence(node)
            node.is_a?(Sequence) && node.parts.one? ? node.parts.first : node
          end

          def subexpression_body(node)
            @subexpressions[node.identifier] || @subexpressions[node.identifier.to_s]
          end

          def emit_command(opcode, operand, target)
            pc = @code.length
            @code << VMInstruction.new(opcode: opcode, operand: operand, target: target)
            pc
          end
        end

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

        # Lower the semantic tree to an immutable linear instruction table.
        # The instruction operand is the precomputed semantic node; nested
        # evaluation remains in the interpreter and never consults the AST.
        def lower(root, extra: {})
          instructions = []
          active = {}.compare_by_identity
          visit = lambda do |node|
            return unless TYPES.include?(node.class)

            index = instructions.index { |instruction| instruction && instruction.operand.equal?(node) }
            return index if index

            index = instructions.length
            instructions << nil
            return index if active[node]

            active[node] = true
            fields = node.each_pair.map { |_field, value| encode(value, visit) }
            instructions[index] = SemanticInstruction.new(opcode: node.class, operand: fields.freeze)
            active.delete(node)
            index
          end
          entry = visit.call(root)
          subexpressions = extra.each_with_object({}) do |(key, node), result|
            result[key] = node
            visit.call(node)
          end
          SemanticProgram.new(instructions: instructions, entry: entry, subexpressions: subexpressions)
        end

        def encode(value, visit)
          return [:__semantic_ref, visit.call(value)].freeze if TYPES.include?(value.class)
          return [:__semantic_array, *value.map { |item| encode(item, visit) }].freeze if value.is_a?(Array)
          return [:__semantic_hash, *value.flat_map { |key, item| [key, encode(item, visit)] }].freeze if value.is_a?(Hash)

          value
        end

        def capture_absence_atom_safe?(node)
          return node.is_a?(Literal) && node.casefold.nil? if node.is_a?(Literal)
          return false unless node.is_a?(Alternation)

          node.branches.all? do |branch|
            branch.is_a?(Sequence) && branch.parts.all? do |part|
              part.is_a?(Literal) && part.casefold.nil?
            end && branch.parts.any?
          end
        end

        def compile(node, casefold: false, parent: nil)
          type = NODE_TYPES.fetch(node.class)
          if node.is_a?(Onibi::AST::Assertion)
            body = compile_value(node.body, casefold: casefold)
            return type.new(body, node.kind, Onibi::WidthAnalysis.widths(node.body),
                            folded_widths(body), flat_assertion_atoms(body, capture: true))
          end
          if node.is_a?(Onibi::AST::Absence)
            body = compile_value(node.body, casefold: casefold)
            group = body.parts.first if body.is_a?(Sequence) && body.parts.one?
            atom = group.body if group.is_a?(Group)
            atom = atom.parts.first if atom.is_a?(Sequence) && atom.parts.one?
            capture = group.is_a?(Group) && group.capture && capture_absence_atom_safe?(atom)
            return type.new(body, flat_assertion_atoms(body, capture: capture))
          end
          if node.is_a?(Onibi::AST::Property)
            return type.new(node.name, node.negated,
                            Onibi::UnicodeProperties.casefold_sequences(node.name))
          end
          return type.new(node.identifier, node.named) if node.is_a?(Onibi::AST::Backreference)

          if node.is_a?(Onibi::AST::Literal)
            return compile_literal(node.value, type)
          end
          if node.is_a?(Onibi::AST::Sequence)
            parts = node.parts.map { |part| compile_value(part, casefold: casefold, parent: :sequence) }
            parts = fuse_casefold_literals(parts) if casefold
            return type.new(parts)
          end
          if node.is_a?(Onibi::AST::Alternation)
            branches = node.branches.map { |branch| compile_value(branch, casefold: casefold, parent: :alternation) }
            policy = if branches.any? { |branch| literal_values(branch).length > 1 && literal_values(branch).any? { |literal| !literal.ascii_only? } }
                       { expanded_branch: true }.freeze
                     elsif branches.any? { |branch| reverse_variant_policy?(branch) }
                       { anchor_alternation: :reject_reverse_variant }.freeze
                     end
            return type.new(branches, parent == :sequence, policy)
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

        def compile_literal(value, type = Literal)
          folded = value.downcase(:fold)
          segments = value.each_char.map { |character| [character, character.downcase(:fold)] }
          segments = nil if segments.all? { |source, item| source == item }
          boundary_sensitive = folded.length > value.length &&
                               folded.each_char.uniq.length > 1 &&
                               folded.each_char.none? { |character| character.match?(/\p{M}/) }
          fold_boundary = fold_boundary_metadata(folded, boundary_sensitive)
          fold_prefix_boundary = fold_prefix_boundary_metadata(value)
          type.new(value, folded == value ? nil : folded, segments&.freeze,
                   boundary_sensitive, fold_boundary, fold_prefix_boundary,
                   fold_policy_for_literal(value))
        end

        def fuse_casefold_literals(parts)
          return parts unless parts.all? { |part| part.is_a?(Literal) }

          parts.chunk_while do |left, right|
            left.is_a?(Literal) && right.is_a?(Literal)
          end.flat_map do |run|
            next run unless run.all? { |part| part.is_a?(Literal) }

            value = run.map(&:value).join
            if run.length > 1 && multi_char_casefold_source?(value)
              [compile_literal(value)]
            else
              run
            end
          end
        end

        def multi_char_casefold_source?(value)
          return false unless value.ascii_only?

          Onibi::UnicodeProperties.casefold_codepoints.any? do |codepoint|
            [codepoint].pack("U").downcase(:fold) == value
          end
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

        def flat_assertion_atoms(node, capture: false)
          case node
          when Literal, CharacterClass, Property, Any, Backreference
            [node].freeze
          when Anchor
            [node].freeze
          when Escape
            return nil unless %i[digit non_digit not_digit word not_word space not_space
                                 horizontal_space not_horizontal_space linebreak
                                 word_boundary not_word_boundary start_match grapheme].include?(node.kind)

            [node].freeze
          when Assertion
            return nil unless capture && node.flat_atoms

            [AssertionAtom.new(node.kind, node.widths, node.flat_atoms)].freeze
          when Conditional
            return nil unless capture

            yes_atoms = flat_assertion_atoms(node.yes_branch, capture: capture)
            no_atoms = flat_assertion_atoms(node.no_branch, capture: capture)
            return nil unless yes_atoms && no_atoms

            [ConditionalAtom.new(node.condition, yes_atoms, no_atoms)].freeze
          when Sequence
            return [] if node.parts.empty?

            atoms = node.parts.map { |part| flat_assertion_atoms(part, capture: capture) }
            return nil unless atoms.all?

            variants = atoms.map do |value|
              value.is_a?(Array) && value.first.is_a?(Array) ? value : [value]
            end
            combined = variants.first.product(*variants.drop(1)).map(&:flatten)
            combined.length == 1 ? combined.first.freeze : combined.freeze
          when Alternation
            variants = node.branches.map { |branch| flat_assertion_atoms(branch, capture: capture) }
            return nil unless variants.all?

            variants.freeze
          when Quantifier
            if node.kind == :+ && node.expression.is_a?(Quantifier) &&
               node.expression.kind == :bounded &&
               node.expression.minimum == node.expression.maximum
              return flat_assertion_atoms(node.expression, capture: capture)
            end

            atoms = flat_assertion_atoms(node.expression, capture: capture)
            return nil unless atoms

            return RepeatAtom.new(atoms.freeze, node.minimum, node.maximum, node.mode) if node.maximum.nil? && capture
            return nil if node.maximum.nil?
            return nil if node.maximum > 32

            if node.minimum == node.maximum
              Array.new(node.minimum) { atoms }.flatten.freeze
            else
              counts = (node.minimum..node.maximum).to_a
              counts.reverse! unless node.mode == :lazy
              counts.map { |count| Array.new(count) { atoms }.flatten }.freeze
            end
          when Group
            if node.capture && capture
              atoms = flat_assertion_atoms(node.body, capture: capture)
              return nil unless atoms

              return CaptureAtom.new(node.number, node.name, atoms.freeze)
            end
            return nil if node.capture

            flat_assertion_atoms(node.body, capture: capture)
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
          reverse_variants = Onibi::UnicodeProperties.reverse_casefold_variants(value.downcase(:fold))
          policy[:anchor_source] = :fold_group_variant if group.any? { |character| character.match?(/\p{M}/) }
          policy[:alternation_source] = :reject_reverse_variant if reverse_variants.any? &&
                                                                   group.any? { |character| character.match?(/\p{M}/) }
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

        # ASCII regular operands are fully represented by DFA labels. Keep
        # them out of the semantic evaluator and execute the flat automaton
        # stream directly.
        def ascii_automaton_only?(node)
          case node
          when Literal
            node.value.ascii_only?
          when Sequence
            node.parts.all? { |part| ascii_automaton_only?(part) }
          when Alternation
            node.branches.all? { |branch| ascii_automaton_only?(branch) }
          else
            false
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

        def reverse_variant_policy?(node)
          case node
          when Literal
            node.fold_policy&.fetch(:alternation_source, nil) == :reject_reverse_variant
          when Sequence
            node.parts.any? { |part| reverse_variant_policy?(part) }
          when Alternation
            node.branches.any? { |branch| reverse_variant_policy?(branch) }
          when Group, OptionGroup, AtomicGroup, Assertion
            reverse_variant_policy?(node.body)
          when Quantifier
            reverse_variant_policy?(node.expression)
          else
            false
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
      # rubocop:enable Metrics/ModuleLength

      Instruction = Struct.new(:opcode, :operand, keyword_init: true) do
        def initialize(opcode:, operand: nil) = super.freeze
      end

      Program = Struct.new(:instructions, :entry, :automaton, :flags, :tagged_automaton,
                           keyword_init: true) do
        def initialize(instructions:, entry: 0, automaton: nil, flags: {}, tagged_automaton: nil)
          super(instructions: instructions.freeze, entry: entry, automaton: automaton,
                flags: flags.freeze, tagged_automaton: tagged_automaton)
          freeze
        end

        def iseq
          self
        end

        # Execute this immutable program through the interpreter boundary.
        def execute(input, start_position = 0, input_view: nil)
          Onibi::IRGen::YARVIR.execute(self, input, start_position, input_view: input_view)
        end

        def execute_with_captures(input, start_position = 0, input_view: nil)
          Onibi::IRGen::YARVIR.execute_with_captures(self, input, start_position, input_view: input_view)
        end

        def tree_free?
          return false if instructions.any? { |instruction| instruction.opcode == :semantic_match }

          flat = instructions.find { |instruction| instruction.opcode == :semantic_flat }&.operand
          return false unless flat

          flat.tree_free? && !contains_ast_payload?(flags)
        end

        private

        def contains_ast_payload?(value)
          return value.any? { |item| contains_ast_payload?(item) } if value.is_a?(Array)
          return value.any? { |key, item| contains_ast_payload?(key) || contains_ast_payload?(item) } if value.is_a?(Hash)
          return true if value.class.name&.start_with?("Onibi::AST::")

          value.respond_to?(:each_pair) && value.each_pair.any? { |_key, item| contains_ast_payload?(item) }
        end
      end
      ISeq = Program

      module_function

      def generate(automaton, mode: nil, flags: {}, semantic_root: nil)
        mode ||= automaton.is_a?(Onibi::Automata::DFA) ? :dfa : :nfa
        return generate_nfa(automaton, flags: flags, semantic_root: semantic_root) if mode == :nfa

        generate_dfa(automaton, flags: flags, semantic_root: semantic_root)
      end

      def generate_dfa(dfa, flags: {}, semantic_root: nil)
        instructions = [Instruction.new(opcode: :start, operand: dfa.start_state.id)]
        flat_runtime = false
        # The semantic matcher is part of the instruction stream. It is
        # placed after `start` so the stream keeps the DFA entry contract.
        if semantic_root
          extras = semantic_contains_call?(semantic_root) ? (flags[:subexpressions] || {}) : {}
          semantic_program = SemanticBytecode.lower(semantic_root, extra: extras)
          flat = semantic_program.flat_program && flat_vm_safe?(flags, semantic_root)
          flat_runtime = flat && !flags.fetch(:retain_semantic_tree, false)
          instructions << Instruction.new(opcode: :semantic_match, operand: semantic_program) unless
            flat_runtime
          instructions << if flat
                            Instruction.new(opcode: :semantic_flat, operand: semantic_program.flat_program)
                          else
                            Instruction.new(opcode: :semantic_vm, operand: semantic_program.vm_instructions)
                          end
        end
        tagged = if flags[:tagged_vm] && !dfa.is_a?(Onibi::Automata::TaggedDFA)
                   Onibi::Automata::TaggedDFA.from_tagged_tnfa(
                     Onibi::Automata::TaggedTNFA.from_tnfa(dfa.tnfa)
                   )
                 else
                   (dfa if dfa.is_a?(Onibi::Automata::TaggedDFA))
                 end
        transitions = tagged ? tagged.transitions : dfa.transitions
        dfa.states.each do |state|
          transitions.each do |key, target|
            source, label, tags = key.is_a?(Array) && key.length == 3 ? key : [key[0], key[1], []]
            next unless source == state.id

            opcode = tags.empty? ? :match : :tagged_match
            semantic_tags = tags.map do |tag|
              Onibi::Automata::Tag.new(kind: tag.kind, value: semantic_value(tag.value))
            end
            operand = semantic_tags.empty? ? semantic_label(label) : [semantic_label(label), semantic_tags.freeze]
            instructions << Instruction.new(opcode: opcode, operand: operand)
            instructions << Instruction.new(opcode: :jump, operand: target)
          end
          instructions << Instruction.new(opcode: :accept, operand: state.id) if state.accepting
        end
        tagged_program = tagged && semantic_tagged_automaton(tagged)
        runtime_flags = flat_runtime ? flags.reject { |key, _value| key == :subexpressions } : flags
        Program.new(instructions: instructions, automaton: semantic_automaton(dfa), flags: runtime_flags,
                    tagged_automaton: tagged_program)
      end

      def generate_nfa(tnfa, flags: {}, semantic_root: nil)
        instructions = [Instruction.new(opcode: :nfa_start, operand: tnfa.start_positions)]
        flat_runtime = false
        if semantic_root
          extras = semantic_contains_call?(semantic_root) ? (flags[:subexpressions] || {}) : {}
          semantic_program = SemanticBytecode.lower(semantic_root, extra: extras)
          flat = semantic_program.flat_program && flat_vm_safe?(flags, semantic_root)
          flat_runtime = flat && !flags.fetch(:retain_semantic_tree, false)
          instructions << Instruction.new(opcode: :semantic_match, operand: semantic_program) unless
            flat_runtime
          instructions << if flat
                            Instruction.new(opcode: :semantic_flat, operand: semantic_program.flat_program)
                          else
                            Instruction.new(opcode: :semantic_vm, operand: semantic_program.vm_instructions)
                          end
        end
        tnfa.transitions.each do |transition|
          instructions << Instruction.new(
            opcode: :nfa_match,
            operand: [transition.from, transition.to,
                      [transition.operation.opcode, semantic_value(transition.operation.operand)]]
          )
        end
        instructions << Instruction.new(opcode: :nfa_accept, operand: tnfa.accept_positions)
        runtime_flags = flat_runtime ? flags.reject { |key, _value| key == :subexpressions } : flags
        Program.new(instructions: instructions, automaton: semantic_automaton(tnfa), flags: runtime_flags)
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

      def semantic_tagged_automaton(tagged)
        copy = tagged.dup
        transitions = tagged.transitions.transform_keys do |(source, label, tags)|
          semantic_tags = Array(tags).map do |tag|
            Onibi::Automata::Tag.new(kind: tag.kind, value: semantic_value(tag.value))
          end
          [source, semantic_label(label), semantic_tags.freeze]
        end.freeze
        copy.instance_variable_set(:@transitions, transitions)
        copy.remove_instance_variable(:@dfa) if copy.instance_variable_defined?(:@dfa)
        copy
      end

      def flat_vm_safe?(flags, semantic_root = nil)
        # Global ignorecase is flat-safe only for one-character ASCII folds.
        # Multi-character reverse folds keep the compatibility path.
        # Boundary-sensitive folds also require source-width conversion before
        # they can enter the character-indexed flat VM.
        return false if flags[:ignorecase] &&
                        !semantic_predicate_leaf_only?(semantic_root) &&
                        !semantic_simple_casefold_safe?(semantic_root) &&
                        !semantic_ascii_literal_sequence_casefold_safe?(semantic_root) &&
                        !semantic_full_fold_literal_only?(semantic_root) &&
                        !semantic_fused_full_fold_literal?(semantic_root) &&
                        !semantic_full_fold_class_only?(semantic_root) &&
                        !semantic_scoped_ascii_class_safe?(semantic_root) &&
                        !semantic_fixed_casefold_sequence_safe?(semantic_root) &&
                        !semantic_terminal_boundary_fold_safe?(semantic_root) &&
                        !semantic_boundary_fold_anchor_safe?(semantic_root) &&
                        !semantic_boundary_fold_start_anchor_safe?(semantic_root) &&
                        !semantic_boundary_fold_lookahead_end_safe?(semantic_root) &&
                        !semantic_trailing_anchor_assertion_safe?(semantic_root) &&
                        !semantic_scoped_negated_class_suffix_safe?(semantic_root)
        return false if flags[:full_casefold] &&
                        !(!flags[:ignorecase] && flags[:literal_only]) &&
                        !semantic_predicate_only?(semantic_root) &&
                        !semantic_full_fold_literal_only?(semantic_root) &&
                        !semantic_fused_full_fold_literal?(semantic_root) &&
                        !semantic_full_fold_class_only?(semantic_root) &&
                        !semantic_scoped_property_quantifier_safe?(semantic_root) &&
                        !semantic_scoped_property_unbounded_quantifier_safe?(semantic_root) &&
                        !semantic_scoped_property_ascii_sequence_safe?(semantic_root) &&
                        !semantic_scoped_property_assertion_sequence_safe?(semantic_root) &&
                        !semantic_scoped_property_alternation_safe?(semantic_root) &&
                        !semantic_scoped_property_alternation_quantifier_safe?(semantic_root) &&
                        !semantic_scoped_property_suffix_safe?(semantic_root) &&
                        !semantic_simple_casefold_safe?(semantic_root) &&
                        !semantic_fixed_casefold_sequence_safe?(semantic_root) &&
                        !semantic_terminal_boundary_fold_safe?(semantic_root) &&
                        !semantic_boundary_fold_anchor_safe?(semantic_root) &&
                        !semantic_boundary_fold_start_anchor_safe?(semantic_root) &&
                        !semantic_boundary_fold_lookahead_end_safe?(semantic_root) &&
                        !semantic_trailing_anchor_assertion_safe?(semantic_root) &&
                        !semantic_scoped_negated_class_suffix_safe?(semantic_root) &&
                        !semantic_nullable_repeat_assertion_safe?(semantic_root)
        return false if flags[:ignorecase] && semantic_contains_full_fold_sequence?(semantic_root) &&
                        !semantic_full_fold_literal_only?(semantic_root) &&
                        !semantic_scoped_property_quantifier_safe?(semantic_root) &&
                        !semantic_scoped_property_unbounded_quantifier_safe?(semantic_root) &&
                        !semantic_scoped_property_ascii_sequence_safe?(semantic_root) &&
                        !semantic_scoped_property_assertion_sequence_safe?(semantic_root) &&
                        !semantic_scoped_property_alternation_safe?(semantic_root) &&
                        !semantic_scoped_property_alternation_quantifier_safe?(semantic_root)
        return false if semantic_root && semantic_scoped_ignorecase_non_ascii_unsafe?(semantic_root) &&
                        !semantic_scoped_ascii_class_safe?(semantic_root) &&
                        !semantic_scoped_full_fold_class_safe?(semantic_root) &&
                        !semantic_scoped_property_safe?(semantic_root) &&
                        !semantic_scoped_literal_absence_safe?(semantic_root) &&
                        !semantic_scoped_property_absence_safe?(semantic_root) &&
                        !semantic_scoped_capture_backreference_safe?(semantic_root) &&
                        !semantic_scoped_capture_conditional_safe?(semantic_root) &&
                        !semantic_scoped_optional_capture_conditional_safe?(semantic_root) &&
                        !semantic_scoped_unicode_repeat_safe?(semantic_root) &&
                        !semantic_scoped_unicode_repeat_alternation_safe?(semantic_root) &&
                        !semantic_scoped_unicode_repeat_suffix_safe?(semantic_root) &&
                        !semantic_scoped_unicode_repeat_capture_suffix_safe?(semantic_root) &&
                        !semantic_scoped_unicode_repeat_internal_suffix_safe?(semantic_root) &&
                        !semantic_scoped_capture_backreference_suffix_safe?(semantic_root) &&
                        !semantic_scoped_capture_conditional_suffix_safe?(semantic_root) &&
                        !semantic_scoped_property_quantifier_safe?(semantic_root) &&
                        !semantic_scoped_property_unbounded_quantifier_safe?(semantic_root) &&
                        !semantic_scoped_property_ascii_sequence_safe?(semantic_root) &&
                        !semantic_scoped_property_assertion_sequence_safe?(semantic_root) &&
                        !semantic_scoped_property_alternation_safe?(semantic_root) &&
                        !semantic_scoped_property_alternation_quantifier_safe?(semantic_root) &&
                        !semantic_scoped_property_suffix_safe?(semantic_root) &&
                        !semantic_terminal_boundary_fold_safe?(semantic_root) &&
                        !semantic_boundary_fold_anchor_safe?(semantic_root) &&
                        !semantic_boundary_fold_start_anchor_safe?(semantic_root) &&
                        !semantic_boundary_fold_lookahead_end_safe?(semantic_root) &&
                        !semantic_trailing_anchor_assertion_safe?(semantic_root)
        return false if semantic_root && semantic_contains_anchor_assertion?(semantic_root) &&
                        !semantic_boundary_fold_lookahead_end_safe?(semantic_root) &&
                        !semantic_leading_start_anchor_assertion_safe?(semantic_root) &&
                        !semantic_terminal_end_assertion_only_safe?(semantic_root) &&
                        !semantic_trailing_anchor_assertion_safe?(semantic_root)
        return false if semantic_root && semantic_scoped_ascii_class_with_suffix?(semantic_root) &&
                        !semantic_scoped_negated_class_suffix_safe?(semantic_root)
        return false if semantic_root && semantic_contains_scoped_simple_unicode_literal?(semantic_root) &&
                        !semantic_standalone_scoped_simple_unicode_literal?(semantic_root) &&
                        !semantic_anchored_scoped_simple_unicode_literal?(semantic_root) &&
                        !semantic_scoped_unicode_repeat_safe?(semantic_root) &&
                        !semantic_scoped_unicode_repeat_alternation_safe?(semantic_root) &&
                        !semantic_scoped_unicode_repeat_suffix_safe?(semantic_root) &&
                        !semantic_scoped_unicode_repeat_capture_suffix_safe?(semantic_root) &&
                        !semantic_scoped_unicode_repeat_internal_suffix_safe?(semantic_root) &&
                        !semantic_scoped_capture_backreference_suffix_safe?(semantic_root) &&
                        !semantic_scoped_capture_conditional_suffix_safe?(semantic_root) &&
                        !semantic_scoped_reverse_fold_suffix_safe?(semantic_root) &&
                        !semantic_scoped_reverse_literal_suffix_safe?(semantic_root)
        return false if semantic_root && semantic_scoped_simple_unicode_with_suffix?(semantic_root) &&
                        !semantic_anchored_scoped_simple_unicode_literal?(semantic_root) &&
                        !semantic_scoped_reverse_fold_suffix_safe?(semantic_root) &&
                        !semantic_scoped_reverse_literal_suffix_safe?(semantic_root)
        return false if semantic_root && semantic_scoped_unicode_bounded_repeat_with_suffix?(semantic_root) &&
                        !semantic_scoped_simple_bounded_repeat_suffix_safe?(semantic_root) &&
                        !semantic_scoped_capture_backreference_suffix_safe?(semantic_root)
        return false if semantic_root && semantic_capture_absence_with_suffix?(semantic_root) &&
                        !semantic_simple_capture_absence_with_suffix?(semantic_root)
        return false if semantic_root && flags[:encoding] &&
                        ![Encoding::UTF_8, Encoding::ASCII_8BIT].include?(flags[:encoding]) &&
                        !semantic_scoped_ascii_class_safe?(semantic_root) &&
                        semantic_contains_non_ascii_operand?(semantic_root)

        !semantic_root.nil?
      end

      def semantic_simple_casefold_safe?(node)
        case node
        when SemanticBytecode::Literal
          value = node.value
          return false unless value.each_char.count == 1

          folded = value.downcase(:fold)
          return false if Onibi::UnicodeProperties.casefold_codepoints.any? do |codepoint|
            [codepoint].pack("U").downcase(:fold) == folded
          end

          folded.length == value.length &&
            Onibi::UnicodeProperties.reverse_casefold_variants(folded).to_a.all? do |variant|
              variant.each_char.count == folded.each_char.count
            end && folded.each_char.all? do |character|
                     Onibi::UnicodeProperties.reverse_casefold_variants(character).all? do |variant|
                       variant.each_char.count == 1
                     end
                   end
        when SemanticBytecode::Sequence
          node.parts.one? && semantic_simple_casefold_safe?(node.parts.first)
        when SemanticBytecode::Alternation
          node.branches.all? { |branch| semantic_simple_casefold_safe?(branch) }
        when SemanticBytecode::Group, SemanticBytecode::OptionGroup, SemanticBytecode::AtomicGroup
          semantic_simple_casefold_safe?(node.body)
        when SemanticBytecode::Quantifier
          node.maximum && node.maximum <= 1 && semantic_simple_casefold_safe?(node.expression)
        else
          false
        end
      end

      def semantic_ascii_literal_sequence_casefold_safe?(node)
        case node
        when SemanticBytecode::Literal
          node.value.ascii_only? && node.value.each_char.one? &&
            (node.casefold.nil? || (node.casefold.ascii_only? && node.casefold.each_char.one?))
        when SemanticBytecode::Sequence
          node.parts.all? { |part| semantic_ascii_literal_sequence_casefold_safe?(part) }
        when SemanticBytecode::Alternation
          node.branches.all? { |branch| semantic_ascii_literal_sequence_casefold_safe?(branch) }
        when SemanticBytecode::Group
          !node.capture && semantic_ascii_literal_sequence_casefold_safe?(node.body)
        else
          false
        end
      end

      def semantic_contains_full_fold_sequence?(node)
        case node
        when SemanticBytecode::Sequence
          values = node.parts.map { |part| part.value if part.is_a?(SemanticBytecode::Literal) }
          return true if values.length > 1 && values.all? && values.join.length > 1 &&
                         Onibi::UnicodeProperties.casefold_codepoints.any? do |codepoint|
                           [codepoint].pack("U").downcase(:fold) == values.join.downcase(:fold)
                         end

          node.parts.any? { |part| semantic_contains_full_fold_sequence?(part) }
        when SemanticBytecode::Group, SemanticBytecode::OptionGroup,
             SemanticBytecode::AtomicGroup
          semantic_contains_full_fold_sequence?(node.body)
        when SemanticBytecode::Alternation
          node.branches.any? { |branch| semantic_contains_full_fold_sequence?(branch) }
        else
          false
        end
      end

      def semantic_full_fold_literal_only?(node)
        return semantic_full_fold_literal_only?(node.body) if
          [SemanticBytecode::Group, SemanticBytecode::OptionGroup].include?(node.class) &&
          (!node.respond_to?(:capture) || !node.capture)
        return false unless node.is_a?(SemanticBytecode::Sequence) && node.parts.one?

        literal = node.parts.first
        return semantic_full_fold_literal_only?(literal) if
          [SemanticBytecode::Group, SemanticBytecode::OptionGroup].include?(literal.class)

        literal.is_a?(SemanticBytecode::Literal) && !literal.fold_boundary_sensitive &&
          literal.value.each_char.count == 1 &&
          literal.casefold.to_s.each_char.count > 1
      end

      def semantic_fused_full_fold_literal?(node)
        return false unless node.is_a?(SemanticBytecode::Sequence) && node.parts.one?

        literal = node.parts.first
        return false unless literal.is_a?(SemanticBytecode::Literal)

        Onibi::UnicodeProperties.casefold_codepoints.any? do |codepoint|
          [codepoint].pack("U").downcase(:fold) == literal.value
        end
      end

      def semantic_full_fold_class_only?(node)
        return false unless node.is_a?(SemanticBytecode::Sequence) && node.parts.one?

        klass = node.parts.first
        klass.is_a?(SemanticBytecode::CharacterClass) && klass.casefolds.any?
      end

      # Predicate operands carry their own compiled table. Their casefold
      # metadata is not used when ignorecase is off, so full-casefold analysis
      # does not require the tree evaluator for this restricted form.
      def semantic_predicate_only?(node)
        case node
        when SemanticBytecode::Property, SemanticBytecode::CharacterClass
          true
        when SemanticBytecode::Group, SemanticBytecode::OptionGroup,
             SemanticBytecode::AtomicGroup
          semantic_predicate_only?(node.body)
        when SemanticBytecode::Sequence
          node.parts.all? { |part| semantic_predicate_only?(part) }
        when SemanticBytecode::Quantifier
          semantic_predicate_only?(node.expression)
        else
          false
        end
      end

      def semantic_predicate_leaf_only?(node)
        return false unless node.is_a?(SemanticBytecode::Sequence) && node.parts.one?

        leaf = node.parts.first
        return true if leaf.is_a?(SemanticBytecode::CharacterClass) ||
                       leaf.is_a?(SemanticBytecode::Property)

          leaf.is_a?(SemanticBytecode::Escape) &&
          %i[digit non_digit not_digit word not_word space not_space horizontal_space
             not_horizontal_space linebreak grapheme word_boundary not_word_boundary].include?(leaf.kind)
      end

      def semantic_contains_non_ascii_operand?(node)
        return true if node.is_a?(SemanticBytecode::Property) && node.name.to_s.casecmp?("ASCII") == false
        return true if node.is_a?(SemanticBytecode::Literal) && !node.value.ascii_only?
        return true if node.is_a?(SemanticBytecode::CharacterClass) && !node.value.ascii_only?

        node.each_pair.any? do |_field, value|
          if value.is_a?(Array)
            value.any? { |item| item.respond_to?(:each_pair) && semantic_contains_non_ascii_operand?(item) }
          elsif value.respond_to?(:each_pair)
            semantic_contains_non_ascii_operand?(value)
          else
            false
          end
        end
      end

      def semantic_scoped_ignorecase_non_ascii?(node)
        return semantic_contains_non_ascii_operand?(node.body) if node.is_a?(SemanticBytecode::OptionGroup) && node.ignorecase

        node.each_pair.any? do |_field, value|
          if value.is_a?(Array)
            value.any? { |item| item.respond_to?(:each_pair) && semantic_scoped_ignorecase_non_ascii?(item) }
          elsif value.respond_to?(:each_pair)
            semantic_scoped_ignorecase_non_ascii?(value)
          else
            false
          end
        end
      end

      def semantic_scoped_ignorecase_non_ascii_unsafe?(node)
        if node.is_a?(SemanticBytecode::OptionGroup) && node.ignorecase && semantic_contains_non_ascii_operand?(node.body) &&
           !semantic_scoped_casefold_simple_safe?(node.body) &&
           !semantic_full_fold_literal_only?(node.body) &&
           !semantic_fixed_casefold_sequence_safe?(node.body) &&
           !semantic_scoped_casefold_predicate_safe?(node.body)
          return true
        end

        node.each_pair.any? do |_field, value|
          if value.is_a?(Array)
            value.any? { |item| item.respond_to?(:each_pair) && semantic_scoped_ignorecase_non_ascii_unsafe?(item) }
          elsif value.respond_to?(:each_pair)
            semantic_scoped_ignorecase_non_ascii_unsafe?(value)
          else
            false
          end
        end
      end

      def semantic_scoped_casefold_simple_safe?(node)
        case node
        when SemanticBytecode::Literal
          folded = node.value.downcase(:fold)
          return true if node.value.each_char.one? && node.casefold.to_s.each_char.count > 1 &&
                         !node.fold_boundary_sensitive

          node.value.each_char.one? && folded.each_char.one? &&
            Onibi::UnicodeProperties.reverse_casefold_variants(folded).all? do |variant|
              variant.each_char.one?
            end
        when SemanticBytecode::Sequence
          return false if node.parts.length > 1 && node.parts.any? do |part|
            part.is_a?(SemanticBytecode::Literal) && !part.value.ascii_only? &&
              (part.fold_boundary_sensitive || semantic_simple_unicode_literal?(part))
          end

          node.parts.all? { |part| semantic_scoped_casefold_simple_safe?(part) }
        when SemanticBytecode::Alternation
          node.branches.all? { |branch| semantic_scoped_casefold_simple_safe?(branch) }
        when SemanticBytecode::Group, SemanticBytecode::OptionGroup, SemanticBytecode::AtomicGroup
          semantic_scoped_casefold_simple_safe?(node.body)
        when SemanticBytecode::Assertion
          %i[positive positive_lookahead negative negative_lookahead
             positive_lookbehind negative_lookbehind].include?(node.kind) &&
            Array(node.flat_atoms).flatten.all? do |atom|
              atom.is_a?(SemanticBytecode::Any) ||
                (atom.is_a?(SemanticBytecode::Literal) &&
                 (atom.value.ascii_only? || semantic_flat_unicode_literal?(atom)))
            end
        when SemanticBytecode::Quantifier
          fixed = node.maximum && node.minimum == node.maximum && node.minimum.positive?
          optional = node.minimum.zero? && node.maximum == 1
          bounded = node.maximum && node.maximum <= 32 && node.minimum <= node.maximum
          unbounded = node.maximum.nil? && node.minimum.positive?
          unbounded_optional = node.maximum.nil? && node.minimum.zero?
          (fixed || optional || bounded || unbounded || unbounded_optional) &&
            semantic_flat_unicode_repeat_operand?(node.expression)
        else
          false
        end
      end

      def semantic_simple_unicode_literal?(node)
        semantic_flat_unicode_literal?(node) &&
          Onibi::UnicodeProperties.reverse_casefold_variants(node.casefold).any?
      end

      def semantic_flat_unicode_literal?(node)
        node.is_a?(SemanticBytecode::Literal) && !node.value.ascii_only? &&
          node.value.each_char.one? && node.casefold.to_s.each_char.one? &&
          !node.fold_boundary_sensitive &&
          Onibi::UnicodeProperties.reverse_casefold_variants(node.casefold).all? do |variant|
            variant.each_char.one?
          end
      end

      def semantic_flat_unicode_repeat_operand?(node)
        return true if semantic_flat_unicode_literal?(node) ||
                       (node.is_a?(SemanticBytecode::Literal) && node.value.ascii_only? &&
                        node.value.each_char.one?)
        return node.branches.all? { |branch| semantic_flat_unicode_repeat_operand?(branch) } if
          node.is_a?(SemanticBytecode::Alternation)
        return node.parts.all? { |part| semantic_flat_unicode_repeat_operand?(part) } if
          node.is_a?(SemanticBytecode::Sequence)
        return semantic_flat_unicode_repeat_operand?(node.body) if
          node.is_a?(SemanticBytecode::Group) || node.is_a?(SemanticBytecode::OptionGroup)

        false
      end

      def semantic_contains_scoped_simple_unicode_literal?(node)
        return true if node.is_a?(SemanticBytecode::OptionGroup) && node.ignorecase &&
                       semantic_standalone_scoped_simple_unicode_literal?(SemanticBytecode::Sequence.new([node]))

        node.each_pair.any? do |_field, value|
          if value.is_a?(Array)
            value.any? { |item| item.respond_to?(:each_pair) && semantic_contains_scoped_simple_unicode_literal?(item) }
          elsif value.respond_to?(:each_pair)
            semantic_contains_scoped_simple_unicode_literal?(value)
          else
            false
          end
        end
      end

      def semantic_standalone_scoped_simple_unicode_literal?(node)
        return false unless node.is_a?(SemanticBytecode::Sequence) && node.parts.one?

        group = node.parts.first
        if group.is_a?(SemanticBytecode::Quantifier)
          return false unless group.minimum == 1 && group.maximum == 1

          group = group.expression
        end
        scoped_simple_unicode_literal?(group)
      end

      def semantic_anchored_scoped_simple_unicode_literal?(node)
        return false unless node.is_a?(SemanticBytecode::Sequence) && node.parts.length == 2

        anchor, group = node.parts
        anchor, group = group, anchor unless anchor.is_a?(SemanticBytecode::Anchor)
        anchor.is_a?(SemanticBytecode::Anchor) &&
          anchor.kind == :anchor_absolute_start &&
          scoped_simple_unicode_literal?(group)
      end

      def semantic_scoped_simple_unicode_with_suffix?(node)
        return false unless node.is_a?(SemanticBytecode::Sequence) && node.parts.length > 1

        node.parts.any? { |part| semantic_contains_scoped_simple_unicode_group?(part) }
      end

      def semantic_scoped_unicode_optional_with_suffix?(node)
        return false unless node.is_a?(SemanticBytecode::Sequence) && node.parts.length > 1

        node.parts.any? do |part|
          semantic_contains_scoped_unicode_optional?(part)
        end
      end

      def semantic_scoped_reverse_fold_suffix_safe?(node)
        return false unless node.is_a?(SemanticBytecode::Sequence) && node.parts.length > 1

        node.parts.each_cons(2).any? do |part, suffix|
          next false unless suffix.is_a?(SemanticBytecode::Literal)
          if part.is_a?(SemanticBytecode::Quantifier) && part.minimum == 1 && part.maximum == 1
            part = part.expression
          end
          next false unless part.is_a?(SemanticBytecode::OptionGroup) && part.ignorecase

          body = part.body
          body = body.parts.first if body.is_a?(SemanticBytecode::Sequence) && body.parts.one?
          body = body.body if body.is_a?(SemanticBytecode::Group) && !body.capture
          next false unless body.is_a?(SemanticBytecode::Alternation)

          literals = body.branches.filter_map do |branch|
            literal = branch.parts.first if branch.is_a?(SemanticBytecode::Sequence) && branch.parts.one?
            literal if literal.is_a?(SemanticBytecode::Literal)
          end
          literals.length == body.branches.length && literals.any? do |literal|
            literal.casefold && literal.value != literal.casefold && literal.value.each_char.one? &&
              literal.casefold.each_char.one?
          end
        end
      end

      def semantic_scoped_reverse_literal_suffix_safe?(node)
        return false unless node.is_a?(SemanticBytecode::Sequence) && node.parts.length > 1

        node.parts.each_cons(2).any? do |part, suffix|
          next false unless suffix.is_a?(SemanticBytecode::Literal)
          next false unless part.is_a?(SemanticBytecode::OptionGroup) && part.ignorecase

          body = part.body
          body = body.parts.first if body.is_a?(SemanticBytecode::Sequence) && body.parts.one?
          body.is_a?(SemanticBytecode::Literal) && body.casefold &&
            body.value != body.casefold && body.value.each_char.one? && body.casefold.each_char.one?
        end
      end

      def semantic_scoped_negated_class_suffix_safe?(node)
        return false unless node.is_a?(SemanticBytecode::Sequence) && node.parts.length > 1

        node.parts.each_cons(2).any? do |part, suffix|
          next false unless suffix.is_a?(SemanticBytecode::OptionGroup) && suffix.ignorecase
          next false unless suffix.body.is_a?(SemanticBytecode::Sequence) && suffix.body.parts.one?
          next false unless suffix.body.parts.first.is_a?(SemanticBytecode::Literal)
          next false unless part.is_a?(SemanticBytecode::Quantifier) && part.expression.is_a?(SemanticBytecode::CharacterClass)

          part.expression.value.start_with?("^") && part.maximum.nil?
        end
      end

      def semantic_nullable_repeat_assertion_safe?(node)
        return false unless node.is_a?(SemanticBytecode::Sequence) && node.parts.length == 2

        repeat, assertion_repeat = node.parts
        return false unless repeat.is_a?(SemanticBytecode::Quantifier) && repeat.minimum.zero? &&
                            repeat.maximum == 1 && repeat.expression.is_a?(SemanticBytecode::Literal)
        return false unless assertion_repeat.is_a?(SemanticBytecode::Quantifier) &&
                            assertion_repeat.minimum == 1 && assertion_repeat.maximum == 1 &&
                            assertion_repeat.expression.is_a?(SemanticBytecode::Assertion)

        assertion = assertion_repeat.expression
        assertion.kind == :negative && assertion.flat_atoms
      end

      def semantic_capture_absence_with_suffix?(node)
        return false unless node.is_a?(SemanticBytecode::Sequence) && node.parts.length > 1

        node.parts.any? do |part|
          part.is_a?(SemanticBytecode::Absence) &&
            part.flat_atoms&.flatten&.any? { |atom| atom.is_a?(SemanticBytecode::CaptureAtom) }
        end
      end

      def semantic_simple_capture_absence_with_suffix?(node)
        return false unless node.is_a?(SemanticBytecode::Sequence)

        node.parts.each_with_index.any? do |part, index|
          next false unless part.is_a?(SemanticBytecode::Absence)

          variants = part.flat_atoms
          variants = [variants] unless variants&.first.is_a?(Array)
          next false unless variants&.all? { |variant| variant.length == 1 && variant.first.is_a?(SemanticBytecode::CaptureAtom) }

          node.parts.drop(index + 1).all? do |suffix|
            suffix.is_a?(SemanticBytecode::Literal) && suffix.casefold.nil?
          end
        end
      end

      def semantic_scoped_unicode_bounded_repeat_with_suffix?(node)
        return false unless node.is_a?(SemanticBytecode::Sequence) && node.parts.length > 1

        node.parts.any? do |part|
          semantic_contains_scoped_unicode_bounded_repeat?(part)
        end
      end

      def semantic_scoped_unicode_repeat_safe?(node)
        return false unless node.is_a?(SemanticBytecode::Sequence) && node.parts.one?

        scope = node.parts.first
        return false unless scope.is_a?(SemanticBytecode::OptionGroup) && scope.ignorecase

        body = scope.body
        body = body.parts.first if body.is_a?(SemanticBytecode::Sequence) && body.parts.one?
        return false unless body.is_a?(SemanticBytecode::Quantifier)

        semantic_scoped_repeat_operand_safe?(body.expression)
      end

      def semantic_scoped_unicode_repeat_suffix_safe?(node)
        return false unless node.is_a?(SemanticBytecode::Sequence) && node.parts.length > 1

        scope, *suffix = node.parts
        return false unless scope.is_a?(SemanticBytecode::OptionGroup) && scope.ignorecase
        return false unless suffix.all? { |part| part.is_a?(SemanticBytecode::Literal) && part.casefold.nil? }

        body = scope.body
        body = body.parts.first if body.is_a?(SemanticBytecode::Sequence) && body.parts.one?
        if body.is_a?(SemanticBytecode::Quantifier)
          return false unless body.maximum.nil?

          semantic_scoped_repeat_operand_safe?(body.expression)
        elsif body.is_a?(SemanticBytecode::Alternation)
          body.branches.all? do |branch|
            branch = branch.parts.first if branch.is_a?(SemanticBytecode::Sequence) && branch.parts.one?
            branch.is_a?(SemanticBytecode::Quantifier) ?
              (branch.maximum.nil? && semantic_scoped_repeat_operand_safe?(branch.expression)) :
              semantic_scoped_repeat_operand_safe?(branch)
          end
        else
          false
        end
      end

      def semantic_scoped_unicode_repeat_capture_suffix_safe?(node)
        return false unless node.is_a?(SemanticBytecode::Sequence) && node.parts.length == 2

        scope, capture = node.parts
        return false unless scope.is_a?(SemanticBytecode::OptionGroup) && scope.ignorecase
        return false unless capture.is_a?(SemanticBytecode::Group) && capture.capture
        return false unless capture.body.is_a?(SemanticBytecode::Sequence) || capture.body.is_a?(SemanticBytecode::Literal)

        body = scope.body
        body = body.parts.first if body.is_a?(SemanticBytecode::Sequence) && body.parts.one?
        return false unless body.is_a?(SemanticBytecode::Quantifier) && body.maximum.nil?

        semantic_scoped_repeat_operand_safe?(body.expression) &&
          semantic_scoped_repeat_operand_safe?(capture.body)
      end

      def semantic_scoped_unicode_repeat_internal_suffix_safe?(node)
        return false unless node.is_a?(SemanticBytecode::Sequence) && node.parts.one?

        scope = node.parts.first
        return false unless scope.is_a?(SemanticBytecode::OptionGroup) && scope.ignorecase

        body = scope.body
        return false unless body.is_a?(SemanticBytecode::Sequence) && body.parts.length > 1
        quantifier, *suffix = body.parts
        return false unless quantifier.is_a?(SemanticBytecode::Quantifier)
        return false unless suffix.all? { |part| part.is_a?(SemanticBytecode::Literal) && part.casefold.nil? }

        semantic_scoped_repeat_operand_safe?(quantifier.expression)
      end

      def semantic_scoped_capture_backreference_suffix_safe?(node)
        return false unless node.is_a?(SemanticBytecode::Sequence) && node.parts.length > 1

        scope, *suffix = node.parts
        return false unless scope.is_a?(SemanticBytecode::OptionGroup) && scope.ignorecase
        return false unless suffix.all? { |part| part.is_a?(SemanticBytecode::Literal) && part.casefold.nil? }

        semantic_scoped_capture_backreference_safe?(SemanticBytecode::Sequence.new([scope]))
      end

      def semantic_scoped_capture_conditional_suffix_safe?(node)
        return false unless node.is_a?(SemanticBytecode::Sequence) && node.parts.length > 1

        scope, *suffix = node.parts
        return false unless scope.is_a?(SemanticBytecode::OptionGroup) && scope.ignorecase
        return false unless suffix.all? { |part| part.is_a?(SemanticBytecode::Literal) && part.casefold.nil? }

        semantic_scoped_capture_conditional_safe?(SemanticBytecode::Sequence.new([scope]))
      end

      def semantic_scoped_unicode_repeat_alternation_safe?(node)
        return false unless node.is_a?(SemanticBytecode::Sequence) && node.parts.one?

        scope = node.parts.first
        return false unless scope.is_a?(SemanticBytecode::OptionGroup) && scope.ignorecase

        body = scope.body
        body = body.parts.first if body.is_a?(SemanticBytecode::Sequence) && body.parts.one?
        return false unless body.is_a?(SemanticBytecode::Alternation)

        body.branches.all? do |branch|
          branch = branch.parts.first if branch.is_a?(SemanticBytecode::Sequence) && branch.parts.one?
          if branch.is_a?(SemanticBytecode::Quantifier)
            semantic_scoped_repeat_operand_safe?(branch.expression)
          else
            semantic_scoped_repeat_operand_safe?(branch)
          end
        end
      end

      def semantic_scoped_repeat_operand_safe?(node)
        return true if node.is_a?(SemanticBytecode::Literal) && node.value.each_char.one? &&
                       (node.value.ascii_only? ||
                        Onibi::UnicodeProperties.reverse_casefold_variants(node.value.downcase(:fold)).all? do |variant|
                          variant.each_char.one?
                        end)

        return node.branches.all? { |branch| semantic_scoped_repeat_operand_safe?(branch) } if
          node.is_a?(SemanticBytecode::Alternation)
        return node.parts.all? { |part| semantic_scoped_repeat_operand_safe?(part) } if
          node.is_a?(SemanticBytecode::Sequence)
        return semantic_scoped_repeat_operand_safe?(node.body) if
          node.is_a?(SemanticBytecode::Group) || node.is_a?(SemanticBytecode::OptionGroup)

        false
      end

      def semantic_scoped_simple_bounded_repeat_suffix_safe?(node)
        return false unless node.is_a?(SemanticBytecode::Sequence) && node.parts.length > 1

        node.parts.each_cons(2).any? do |part, suffix|
          next false unless suffix.is_a?(SemanticBytecode::Literal)
          next false unless part.is_a?(SemanticBytecode::OptionGroup) && part.ignorecase

          body = part.body
          body = body.parts if body.is_a?(SemanticBytecode::Sequence)
          body = [body] unless body.is_a?(Array)
          quantifier = body.find { |item| item.is_a?(SemanticBytecode::Quantifier) }
          next false unless quantifier && quantifier.maximum && quantifier.maximum > quantifier.minimum

          expression = quantifier.expression
          expression.is_a?(SemanticBytecode::Literal) && expression.casefold &&
            expression.value.each_char.one? && expression.casefold.each_char.one?
        end
      end

      def semantic_contains_scoped_unicode_bounded_repeat?(node)
        return true if node.is_a?(SemanticBytecode::OptionGroup) && node.ignorecase &&
                       semantic_contains_unicode_bounded_repeat?(node.body)

        node.each_pair.any? do |_field, value|
          if value.is_a?(Array)
            value.any? { |item| item.respond_to?(:each_pair) && semantic_contains_scoped_unicode_bounded_repeat?(item) }
          elsif value.respond_to?(:each_pair)
            semantic_contains_scoped_unicode_bounded_repeat?(value)
          else
            false
          end
        end
      end

      def semantic_contains_unicode_bounded_repeat?(node)
        return true if node.is_a?(SemanticBytecode::Quantifier) && node.maximum &&
                       node.maximum > 1 && semantic_contains_non_ascii_operand?(node.expression)

        node.each_pair.any? do |_field, value|
          if value.is_a?(Array)
            value.any? { |item| item.respond_to?(:each_pair) && semantic_contains_unicode_bounded_repeat?(item) }
          elsif value.respond_to?(:each_pair)
            semantic_contains_unicode_bounded_repeat?(value)
          else
            false
          end
        end
      end

      def semantic_contains_scoped_unicode_optional?(node)
        return true if node.is_a?(SemanticBytecode::OptionGroup) && node.ignorecase &&
                       semantic_contains_unicode_optional?(node.body)

        node.each_pair.any? do |_field, value|
          if value.is_a?(Array)
            value.any? { |item| item.respond_to?(:each_pair) && semantic_contains_scoped_unicode_optional?(item) }
          elsif value.respond_to?(:each_pair)
            semantic_contains_scoped_unicode_optional?(value)
          else
            false
          end
        end
      end

      def semantic_contains_unicode_optional?(node)
        return true if node.is_a?(SemanticBytecode::Quantifier) && node.minimum.zero? &&
                       node.maximum == 1 && semantic_contains_non_ascii_operand?(node.expression)

        node.each_pair.any? do |_field, value|
          if value.is_a?(Array)
            value.any? { |item| item.respond_to?(:each_pair) && semantic_contains_unicode_optional?(item) }
          elsif value.respond_to?(:each_pair)
            semantic_contains_unicode_optional?(value)
          else
            false
          end
        end
      end

      def semantic_contains_scoped_simple_unicode_group?(node)
        return true if node.is_a?(SemanticBytecode::OptionGroup) && node.ignorecase &&
                       semantic_contains_simple_unicode_literal?(node.body)

        node.each_pair.any? do |_field, value|
          if value.is_a?(Array)
            value.any? { |item| item.respond_to?(:each_pair) && semantic_contains_scoped_simple_unicode_group?(item) }
          elsif value.respond_to?(:each_pair)
            semantic_contains_scoped_simple_unicode_group?(value)
          else
            false
          end
        end
      end

      def semantic_contains_simple_unicode_literal?(node)
        return true if semantic_simple_unicode_literal?(node)

        node.each_pair.any? do |_field, value|
          if value.is_a?(Array)
            value.any? { |item| item.respond_to?(:each_pair) && semantic_contains_simple_unicode_literal?(item) }
          elsif value.respond_to?(:each_pair)
            semantic_contains_simple_unicode_literal?(value)
          else
            false
          end
        end
      end

      def scoped_simple_unicode_literal?(group)
        return false unless group.is_a?(SemanticBytecode::OptionGroup) && group.ignorecase

        body = group.body
        body = body.parts.first if body.is_a?(SemanticBytecode::Sequence) && body.parts.one?
        body.is_a?(SemanticBytecode::Literal) && !body.value.ascii_only? &&
          body.value.each_char.one? && body.casefold.to_s.each_char.one? &&
          !body.fold_boundary_sensitive &&
          Onibi::UnicodeProperties.reverse_casefold_variants(body.casefold).any? &&
          Onibi::UnicodeProperties.reverse_casefold_variants(body.casefold).all? do |variant|
            variant.each_char.one?
          end
      end

      def semantic_fixed_casefold_sequence_safe?(node)
        case node
        when SemanticBytecode::Literal
          folded = node.value.downcase(:fold)
          node.value.each_char.one? &&
            ((node.casefold.to_s.each_char.count > 1 && !node.fold_boundary_sensitive) ||
             (folded == node.value && Onibi::UnicodeProperties.reverse_casefold_variants(folded).empty?))
        when SemanticBytecode::Sequence
          node.parts.any? && node.parts.all? { |part| semantic_fixed_casefold_sequence_safe?(part) }
        when SemanticBytecode::OptionGroup
          node.ignorecase && semantic_fixed_casefold_sequence_safe?(node.body)
        else
          false
        end
      end

      def semantic_terminal_boundary_fold_safe?(node)
        scoped = if node.is_a?(SemanticBytecode::Sequence) && node.parts.one?
                   node.parts.first
                 else
                   node
                 end
        return false unless scoped.is_a?(SemanticBytecode::OptionGroup) && scoped.ignorecase

        body = scoped.body
        body = body.parts.first if body.is_a?(SemanticBytecode::Sequence) && body.parts.one?
        body.is_a?(SemanticBytecode::Literal) && body.fold_boundary_sensitive &&
          body.value.each_char.one?
      end

      def semantic_boundary_fold_anchor_safe?(node)
        return false unless node.is_a?(SemanticBytecode::Sequence) && node.parts.length >= 2

        scoped = node.parts.first
        return false unless scoped.is_a?(SemanticBytecode::OptionGroup) && scoped.ignorecase

        body = scoped.body
        body = body.parts.first if body.is_a?(SemanticBytecode::Sequence) && body.parts.one?
        return false unless body.is_a?(SemanticBytecode::Literal) && body.fold_boundary_sensitive

        body.value.each_char.one? && node.parts.drop(1).all? do |part|
          part.is_a?(SemanticBytecode::Anchor)
        end
      end

      def semantic_boundary_fold_start_anchor_safe?(node)
        return false unless node.is_a?(SemanticBytecode::Sequence) && node.parts.length == 2
        return false unless node.parts.first.is_a?(SemanticBytecode::Anchor) &&
                            node.parts.first.kind == :anchor_absolute_start

        scoped = node.parts.last
        return false unless scoped.is_a?(SemanticBytecode::OptionGroup) && scoped.ignorecase

        body = scoped.body
        body = body.parts.first if body.is_a?(SemanticBytecode::Sequence) && body.parts.one?
        body.is_a?(SemanticBytecode::Literal) && body.fold_boundary_sensitive &&
          body.value.each_char.one?
      end

      def semantic_contains_anchor_assertion?(node)
        return true if node.is_a?(SemanticBytecode::Assertion) &&
                       Array(node.flat_atoms).flatten.any? { |atom| atom.is_a?(SemanticBytecode::Anchor) }

        node.each_pair.any? do |_field, value|
          if value.is_a?(Array)
            value.any? { |item| item.respond_to?(:each_pair) && semantic_contains_anchor_assertion?(item) }
          elsif value.respond_to?(:each_pair)
            semantic_contains_anchor_assertion?(value)
          else
            false
          end
        end
      end

      def semantic_leading_start_anchor_assertion_safe?(node)
        return false unless node.is_a?(SemanticBytecode::Sequence) && node.parts.length > 1

        assertion, *suffix = node.parts
        return false unless assertion.is_a?(SemanticBytecode::Assertion) &&
                            %i[positive positive_lookahead negative negative_lookahead].include?(assertion.kind)
        atoms = Array(assertion.flat_atoms).flatten
        return false unless atoms.length == 1 && atoms.first.is_a?(SemanticBytecode::Anchor) &&
                            atoms.first.kind == :anchor_absolute_start

        suffix.all? { |part| semantic_consuming_operand?(part) }
      end

      def semantic_terminal_end_assertion_only_safe?(node)
        return false unless node.is_a?(SemanticBytecode::Sequence) && node.parts.one?

        assertion = node.parts.first
        return false unless assertion.is_a?(SemanticBytecode::Assertion) &&
                            %i[positive positive_lookahead negative negative_lookahead].include?(assertion.kind)

        atoms = Array(assertion.flat_atoms).flatten
        atoms.length == 1 && atoms.first.is_a?(SemanticBytecode::Anchor) &&
          %i[anchor_absolute_end anchor_before_final_newline].include?(atoms.first.kind)
      end

      def semantic_boundary_fold_lookahead_end_safe?(node)
        return false unless node.is_a?(SemanticBytecode::Sequence) && node.parts.length == 2

        scoped, assertion = node.parts
        return false unless scoped.is_a?(SemanticBytecode::OptionGroup) && scoped.ignorecase

        body = scoped.body
        body = body.parts.first if body.is_a?(SemanticBytecode::Sequence) && body.parts.one?
        return false unless body.is_a?(SemanticBytecode::Literal) && body.fold_boundary_sensitive
        return false unless assertion.is_a?(SemanticBytecode::Assertion) &&
                            %i[positive negative].include?(assertion.kind)

        atoms = Array(assertion.flat_atoms).flatten
        atoms.length == 1 && atoms.first.is_a?(SemanticBytecode::Anchor) &&
          atoms.first.kind == :anchor_absolute_end && body.value.each_char.one?
      end

      # A trailing anchor assertion is safe when the assertion follows a
      # consuming prefix. A leading assertion can change search semantics.
      def semantic_trailing_anchor_assertion_safe?(node)
        return false unless node.is_a?(SemanticBytecode::Sequence) && node.parts.length >= 2

        assertion = node.parts.last
        return false unless assertion.is_a?(SemanticBytecode::Assertion)
        return false unless %i[positive negative].include?(assertion.kind)

        atoms = Array(assertion.flat_atoms).flatten
        return false unless atoms.length == 1 && atoms.first.is_a?(SemanticBytecode::Anchor)
        return false unless %i[anchor_absolute_end anchor_absolute_start].include?(atoms.first.kind)

        prefix = node.parts[0...-1]
        prefix.none? { |part| semantic_contains_anchor_assertion?(part) } &&
          prefix.all? { |part| semantic_consuming_operand?(part) }
      end

      def semantic_consuming_operand?(node)
        case node
        when SemanticBytecode::Literal, SemanticBytecode::CharacterClass,
             SemanticBytecode::Property, SemanticBytecode::Any,
             SemanticBytecode::Escape, SemanticBytecode::Backreference
          true
        when SemanticBytecode::Group, SemanticBytecode::AtomicGroup
          !node.capture && semantic_consuming_operand?(node.body)
        when SemanticBytecode::OptionGroup
          semantic_consuming_operand?(node.body)
        when SemanticBytecode::Sequence
          node.parts.all? { |part| semantic_consuming_operand?(part) }
        when SemanticBytecode::Alternation
          node.branches.all? { |branch| semantic_consuming_operand?(branch) }
        when SemanticBytecode::Quantifier
          node.minimum.positive? && semantic_consuming_operand?(node.expression)
        else
          false
        end
      end

      def semantic_scoped_casefold_predicate_safe?(node)
        case node
        when SemanticBytecode::CharacterClass
          node.casefolds.empty? &&
            node.folded_characters.all? { |character| character.each_char.count == 1 } &&
            node.fold_boundaries.empty?
        when SemanticBytecode::Property
          fold_invariant_property?(node)
        when SemanticBytecode::Sequence
          node.parts.all? { |part| semantic_scoped_casefold_predicate_safe?(part) }
        when SemanticBytecode::OptionGroup, SemanticBytecode::Group, SemanticBytecode::AtomicGroup
          semantic_scoped_casefold_predicate_safe?(node.body)
        else
          false
        end
      end

      def semantic_scoped_ascii_class_safe?(node)
        return false unless node.is_a?(SemanticBytecode::Sequence) && node.parts.one?

        group = node.parts.first
        return false unless group.is_a?(SemanticBytecode::OptionGroup) && group.ignorecase

        body = group.body
        body = body.parts.first if body.is_a?(SemanticBytecode::Sequence) && body.parts.one?
        body.is_a?(SemanticBytecode::CharacterClass) && body.casefolds.empty? &&
          body.folded_characters.all? { |character| character.each_char.count == 1 } &&
          body.fold_boundaries.values.compact.all? { |boundary| boundary[:kind] == :simple_fold_source }
      end

      def semantic_scoped_ascii_class_with_suffix?(node)
        return false unless node.is_a?(SemanticBytecode::Sequence) && node.parts.length > 1

        node.parts.any? do |part|
          part.is_a?(SemanticBytecode::OptionGroup) && part.ignorecase &&
            semantic_scoped_ascii_class_safe?(SemanticBytecode::Sequence.new([part])) &&
            begin
              body = part.body
              body = body.parts.first if body.is_a?(SemanticBytecode::Sequence) && body.parts.one?
              body.is_a?(SemanticBytecode::CharacterClass) && body.fold_boundaries.values.compact.any?
            end
        end
      end

      def semantic_scoped_full_fold_class_safe?(node)
        return false unless node.is_a?(SemanticBytecode::Sequence) && node.parts.one?

        group = node.parts.first
        return false unless group.is_a?(SemanticBytecode::OptionGroup) && group.ignorecase

        body = group.body
        body = body.parts.first if body.is_a?(SemanticBytecode::Sequence) && body.parts.one?
        body.is_a?(SemanticBytecode::CharacterClass) && body.casefolds.length == 1 &&
          body.casefolds.all? { |_source, folded| folded.each_char.count == 2 }
      end

      def semantic_scoped_property_safe?(node)
        return false unless node.is_a?(SemanticBytecode::Sequence) && node.parts.one?

        group = node.parts.first
        return false unless group.is_a?(SemanticBytecode::OptionGroup) && group.ignorecase

        body = group.body
        body = body.parts.first if body.is_a?(SemanticBytecode::Sequence) && body.parts.one?
        body.is_a?(SemanticBytecode::Property) &&
          Onibi::UnicodeProperties::PROPERTY_MATCHERS.key?(
            Onibi::UnicodeProperties.normalize_name(body.name.to_s)
          )
      rescue RegexpError, KeyError
        false
      end

      def semantic_scoped_literal_absence_safe?(node)
        return false unless node.is_a?(SemanticBytecode::Sequence) && node.parts.length > 1

        scope, *suffix = node.parts
        return false unless scope.is_a?(SemanticBytecode::OptionGroup) && scope.ignorecase
        return false unless suffix.all? { |part| part.is_a?(SemanticBytecode::Literal) && part.value.ascii_only? }

        body = scope.body
        body = body.parts.first if body.is_a?(SemanticBytecode::Sequence) && body.parts.one?
        body.is_a?(SemanticBytecode::Absence) &&
          Array(body.flat_atoms).flatten.all? { |atom| atom.is_a?(SemanticBytecode::Literal) && atom.value.ascii_only? }
      end

      def semantic_scoped_property_absence_safe?(node)
        return false unless node.is_a?(SemanticBytecode::Sequence) && node.parts.length > 1

        scope, *suffix = node.parts
        return false unless scope.is_a?(SemanticBytecode::OptionGroup) && scope.ignorecase
        return false unless suffix.all? { |part| part.is_a?(SemanticBytecode::Literal) && part.value.ascii_only? }

        body = scope.body
        body = body.parts.first if body.is_a?(SemanticBytecode::Sequence) && body.parts.one?
        return false unless body.is_a?(SemanticBytecode::Absence)

        Array(body.flat_atoms).flatten.all? do |atom|
          atom.is_a?(SemanticBytecode::Property) &&
            Onibi::UnicodeProperties::PROPERTY_MATCHERS.key?(
              Onibi::UnicodeProperties.normalize_name(atom.name.to_s)
            )
        end
      rescue RegexpError, KeyError
        false
      end

      def semantic_scoped_capture_backreference_safe?(node)
        return false unless node.is_a?(SemanticBytecode::Sequence) && node.parts.one?

        group = node.parts.first
        return false unless group.is_a?(SemanticBytecode::OptionGroup) && group.ignorecase
        body = group.body
        body = body.parts.first if body.is_a?(SemanticBytecode::Sequence) && body.parts.one?
        return false unless body.is_a?(SemanticBytecode::Sequence) && body.parts.length == 2

        capture, reference = body.parts
        if capture.is_a?(SemanticBytecode::Quantifier) &&
           (capture.maximum.nil? || capture.minimum == capture.maximum)
          capture = capture.expression
        end
        return false unless capture.is_a?(SemanticBytecode::Group) && capture.capture
        return false unless reference.is_a?(SemanticBytecode::Backreference)
        numbered_reference = !reference.named && reference.identifier == capture.number
        named_reference = reference.named && reference.identifier == capture.name
        return false unless numbered_reference || named_reference

        semantic_capture_backreference_body_safe?(capture.body)
      end

      def semantic_capture_backreference_body_safe?(node)
        loop do
          unwrapped = node.parts.first if node.is_a?(SemanticBytecode::Sequence) && node.parts.one?
          unwrapped = node.body if node.is_a?(SemanticBytecode::Group)
          break unless unwrapped

          node = unwrapped
        end
        return node.branches.all? { |branch| semantic_capture_backreference_body_safe?(branch) } \
          if node.is_a?(SemanticBytecode::Alternation)

        if node.is_a?(SemanticBytecode::Quantifier)
          return false unless node.maximum.nil? || (node.minimum == node.maximum && node.minimum.positive?)

          return semantic_capture_backreference_body_safe?(node.expression)
        end

        return false unless node.is_a?(SemanticBytecode::Literal)
        return false unless node.value.each_char.one?
        return true if node.value.ascii_only?
        return false unless node.value.encoding == Encoding::UTF_8

        Onibi::UnicodeProperties.reverse_casefold_variants(node.value.downcase(:fold)).all? do |variant|
          variant.each_char.one?
        end
      end

      def semantic_scoped_capture_conditional_safe?(node)
        return false unless node.is_a?(SemanticBytecode::Sequence) && node.parts.one?

        group = node.parts.first
        return false unless group.is_a?(SemanticBytecode::OptionGroup) && group.ignorecase
        body = group.body
        body = body.parts.first if body.is_a?(SemanticBytecode::Sequence) && body.parts.one?
        return false unless body.is_a?(SemanticBytecode::Sequence) && body.parts.length == 2

        capture, conditional = body.parts
        if capture.is_a?(SemanticBytecode::Quantifier) &&
           capture.maximum && capture.minimum == capture.maximum
          capture = capture.expression
        end
        return false unless capture.is_a?(SemanticBytecode::Group) && capture.capture
        return false unless conditional.is_a?(SemanticBytecode::Conditional)
        condition = conditional.condition.is_a?(Array) ? conditional.condition.first : conditional.condition
        return false unless condition == capture.number || condition == capture.name

        [conditional.yes_branch, conditional.no_branch].compact.all? do |branch|
          semantic_scoped_conditional_branch_safe?(branch)
        end
      end

      def semantic_scoped_conditional_branch_safe?(branch)
        node = branch
        node = node.parts.first if node.is_a?(SemanticBytecode::Sequence) && node.parts.one?
        return node.parts.all? { |part| semantic_scoped_conditional_branch_safe?(part) } if
          node.is_a?(SemanticBytecode::Sequence)
        return node.branches.all? { |candidate| semantic_scoped_conditional_branch_safe?(candidate) } if
          node.is_a?(SemanticBytecode::Alternation)
        return semantic_scoped_conditional_branch_safe?(node.body) if
          node.is_a?(SemanticBytecode::Group) && !node.capture
        return true if node.is_a?(SemanticBytecode::Property) &&
                       Onibi::UnicodeProperties::PROPERTY_MATCHERS.key?(
                         Onibi::UnicodeProperties.normalize_name(node.name.to_s)
                       )

        return true if node.is_a?(SemanticBytecode::Any)
        return Array(node.flat_atoms).flatten.all? do |atom|
          semantic_scoped_repeat_operand_safe?(atom)
        end if node.is_a?(SemanticBytecode::Assertion) &&
               %i[positive positive_lookahead negative negative_lookahead
                  positive_lookbehind negative_lookbehind].include?(node.kind)
        return true if node.is_a?(SemanticBytecode::Escape) &&
                       %i[digit non_digit not_digit word not_word space not_space horizontal_space
                          not_horizontal_space linebreak grapheme].include?(node.kind)

        semantic_scoped_repeat_operand_safe?(node)
      rescue RegexpError, KeyError
        false
      end

      def semantic_scoped_optional_capture_conditional_safe?(node)
        return false unless node.is_a?(SemanticBytecode::Sequence) && node.parts.one?

        group = node.parts.first
        return false unless group.is_a?(SemanticBytecode::OptionGroup) && group.ignorecase
        body = group.body
        body = body.parts.first if body.is_a?(SemanticBytecode::Sequence) && body.parts.one?
        return false unless body.is_a?(SemanticBytecode::Sequence) && body.parts.length == 2

        quantifier, conditional = body.parts
        return false unless quantifier.is_a?(SemanticBytecode::Quantifier)
        return false unless quantifier.minimum.zero? && quantifier.maximum == 1
        capture = quantifier.expression
        return false unless capture.is_a?(SemanticBytecode::Group) && capture.capture
        return false unless conditional.is_a?(SemanticBytecode::Conditional)
        condition = conditional.condition.is_a?(Array) ? conditional.condition.first : conditional.condition
        return false unless condition == capture.number

        [conditional.yes_branch, conditional.no_branch].compact.all? do |branch|
          semantic_scoped_conditional_branch_safe?(branch)
        end
      end

      def semantic_scoped_property_suffix_safe?(node)
        return false unless node.is_a?(SemanticBytecode::Sequence) && node.parts.length > 1

        scope, *suffix = node.parts
        return false unless scope.is_a?(SemanticBytecode::OptionGroup) && scope.ignorecase
        body = scope.body
        body = body.parts.first if body.is_a?(SemanticBytecode::Sequence) && body.parts.one?
        return false unless body.is_a?(SemanticBytecode::Property)
        return false unless suffix.all? do |part|
          part.is_a?(SemanticBytecode::Literal) && part.value.ascii_only?
        end

        semantic_scoped_property_safe?(SemanticBytecode::Sequence.new([scope]))
      end

      def semantic_scoped_property_ascii_sequence_safe?(node)
        return false unless node.is_a?(SemanticBytecode::Sequence) && node.parts.length > 1

        scope, *suffix = node.parts
        return false unless scope.is_a?(SemanticBytecode::OptionGroup) && scope.ignorecase
        return false unless suffix.all? { |part| part.is_a?(SemanticBytecode::Literal) && part.value.ascii_only? }

        body = scope.body
        body = body.parts.first if body.is_a?(SemanticBytecode::Sequence) && body.parts.one?
        return false unless body.is_a?(SemanticBytecode::Sequence) && body.parts.length > 1

        first, *rest = body.parts
        return false unless first.is_a?(SemanticBytecode::Property)
        rest.all? do |part|
          part.is_a?(SemanticBytecode::Any) ||
            (part.is_a?(SemanticBytecode::Escape) &&
             %i[digit non_digit not_digit word not_word space not_space horizontal_space
                not_horizontal_space linebreak grapheme word_boundary not_word_boundary].include?(part.kind))
        end
      end

      def semantic_scoped_property_assertion_sequence_safe?(node)
        return false unless node.is_a?(SemanticBytecode::Sequence) && node.parts.length > 1

        scope, *suffix = node.parts
        return false unless scope.is_a?(SemanticBytecode::OptionGroup) && scope.ignorecase
        return false unless suffix.all? { |part| part.is_a?(SemanticBytecode::Literal) && part.value.ascii_only? }

        body = scope.body
        body = body.parts.first if body.is_a?(SemanticBytecode::Sequence) && body.parts.one?
        return false unless body.is_a?(SemanticBytecode::Sequence) && body.parts.length > 1

        assertions = body.parts.select { |part| part.is_a?(SemanticBytecode::Assertion) }
        properties = body.parts.select { |part| part.is_a?(SemanticBytecode::Property) }
        return false unless assertions.one? && properties.one?

        assertion = assertions.first
        assertion &&
          %i[positive positive_lookahead negative negative_lookahead
             positive_lookbehind negative_lookbehind].include?(assertion.kind) &&
          Array(assertion.flat_atoms).flatten.all? do |atom|
            atom.is_a?(SemanticBytecode::Any) ||
              (atom.is_a?(SemanticBytecode::Literal) && atom.value.ascii_only?)
          end &&
          body.parts.all? do |part|
            part.equal?(assertion) || part.equal?(properties.first) ||
              part.is_a?(SemanticBytecode::Any) ||
              (part.is_a?(SemanticBytecode::Escape) &&
               %i[digit non_digit not_digit word not_word space not_space horizontal_space
                  not_horizontal_space linebreak grapheme].include?(part.kind)) ||
              (part.is_a?(SemanticBytecode::Literal) && part.value.ascii_only?)
          end
      end

      def semantic_scoped_property_quantifier_safe?(node)
        return false unless node.is_a?(SemanticBytecode::Sequence) && node.parts.any?

        quantifier, *suffix = node.parts
        return false unless quantifier.is_a?(SemanticBytecode::Quantifier)
        return false unless quantifier.minimum.positive? ||
                            (quantifier.minimum.zero? &&
                             (quantifier.maximum.nil? || quantifier.maximum <= 32))
        return false unless suffix.all? do |part|
          part.is_a?(SemanticBytecode::Literal) && part.value.ascii_only?
        end

        semantic_scoped_property_safe?(SemanticBytecode::Sequence.new([quantifier.expression]))
      end

      def semantic_scoped_property_unbounded_quantifier_safe?(node)
        return false unless node.is_a?(SemanticBytecode::Sequence) && node.parts.length > 1

        quantifier, *suffix = node.parts
        return false unless quantifier.is_a?(SemanticBytecode::Quantifier)
        return false unless quantifier.minimum.zero? && quantifier.maximum.nil?
        return false unless suffix.all? { |part| part.is_a?(SemanticBytecode::Literal) && part.value.ascii_only? }

        semantic_scoped_property_safe?(SemanticBytecode::Sequence.new([quantifier.expression]))
      end

      def semantic_scoped_property_alternation_safe?(node)
        return false unless node.is_a?(SemanticBytecode::Sequence) && node.parts.any?

        group, *suffix = node.parts
        return false unless group.is_a?(SemanticBytecode::OptionGroup) && group.ignorecase
        return false unless suffix.all? do |part|
          part.is_a?(SemanticBytecode::Literal) && part.value.ascii_only?
        end

        body = group.body
        body = body.parts.first if body.is_a?(SemanticBytecode::Sequence) && body.parts.one?
        body = body.body if body.is_a?(SemanticBytecode::Group) && !body.capture
        return false unless body.is_a?(SemanticBytecode::Alternation)

        body.branches.all? do |branch|
          branch_node = branch
          branch_node = branch_node.parts.first if
            branch_node.is_a?(SemanticBytecode::Sequence) && branch_node.parts.one?
          if branch_node.is_a?(SemanticBytecode::Property)
            semantic_scoped_property_safe?(SemanticBytecode::Sequence.new([
              SemanticBytecode::OptionGroup.new(branch_node, true, nil, nil)
            ]))
          else
            semantic_ascii_literal_sequence_casefold_safe?(SemanticBytecode::Sequence.new([branch_node]))
          end
        end
      end

      def semantic_scoped_property_alternation_quantifier_safe?(node)
        return false unless node.is_a?(SemanticBytecode::Sequence) && node.parts.any?

        quantifier, *suffix = node.parts
        return false unless quantifier.is_a?(SemanticBytecode::Quantifier)
        return false unless quantifier.minimum.positive? ||
                            (quantifier.minimum.zero? &&
                             (quantifier.maximum.nil? || quantifier.maximum <= 32))
        return false unless suffix.all? do |part|
          part.is_a?(SemanticBytecode::Literal) && part.value.ascii_only?
        end

        semantic_scoped_property_alternation_safe?(SemanticBytecode::Sequence.new([
          quantifier.expression
        ]))
      end

      def fold_invariant_property?(node)
        node.casefolds.empty?
      rescue RegexpError, KeyError
        false
      end

      def semantic_contains_call?(node)
        return true if node.is_a?(SemanticBytecode::SubexpressionCall)

        node.each_pair.any? do |_field, value|
          if value.is_a?(Array)
            value.any? { |item| item.respond_to?(:each_pair) && semantic_contains_call?(item) }
          elsif value.respond_to?(:each_pair)
            semantic_contains_call?(value)
          else
            false
          end
        end
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
