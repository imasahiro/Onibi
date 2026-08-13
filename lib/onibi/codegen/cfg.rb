# frozen_string_literal: true

module Onibi
  module Codegen
    # Immutable control-flow representation used between parsing and Ruby emission.
    module CFG
      StateToken = Struct.new(:domain, :version, keyword_init: true) do
        def initialize(domain:, version:)
          super
          freeze
        end
      end

      EffectSummary = Struct.new(:effects, :reads, :writes, keyword_init: true) do
        def initialize(effects: [], reads: {}, writes: {})
          normalized = ->(value) { value.uniq.freeze }
          super(effects: normalized.call(effects), reads: freeze_tokens(reads), writes: freeze_tokens(writes))
          freeze
        end

        def self.from_operations(operations)
          new(effects: operations.flat_map(&:effects), reads: collect_tokens(operations, :state_in),
              writes: collect_tokens(operations, :state_out))
        end

        private

        def self.collect_tokens(operations, field)
          operations.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |operation, result|
            operation.public_send(field).each { |domain, token| result[domain] << token }
          end
        end

        def freeze_tokens(tokens)
          tokens.each_with_object({}) do |(domain, values), result|
            result[domain] = values.uniq.freeze
          end.freeze
        end
      end

      Operation = Struct.new(:opcode, :operand, :effects, :state_in, :state_out, keyword_init: true) do
        def initialize(opcode:, operand: nil, effects: [], state_in: {}, state_out: {})
          super(opcode: opcode, operand: operand, effects: effects.dup.freeze,
                state_in: state_in.dup.freeze, state_out: state_out.dup.freeze)
          freeze
        end
      end

      Terminator = Struct.new(:opcode, keyword_init: true) do
        def initialize(opcode:)
          super
          freeze
        end
      end

      Edge = Struct.new(:target, :kind, :priority, keyword_init: true) do
        def initialize(target:, kind: :flow, priority: 0)
          super
          freeze
        end
      end

      Block = Struct.new(:id, :operations, :terminator, :successors, :effect_summary, keyword_init: true) do
        def initialize(id:, operations:, terminator:, successors:, effect_summary: nil)
          super(id: id, operations: operations.freeze, terminator: terminator, successors: successors.freeze)
          self.effect_summary = effect_summary || EffectSummary.from_operations(operations)
          freeze
        end
      end

      Graph = Struct.new(:entry, :exit, :blocks, :effect_summary, :dominators, keyword_init: true) do
        def initialize(entry:, exit:, blocks:, effect_summary: nil, dominators: nil)
          super(entry: entry, exit: exit, blocks: blocks.freeze,
                effect_summary: effect_summary || EffectSummary.from_operations(blocks.flat_map(&:operations)),
                dominators: dominators || Dominance.compute(entry, blocks))
          freeze
        end

        def operations
          blocks.flat_map(&:operations).freeze
        end
      end

      # Computes immutable dominator sets for ordered CFG blocks.
      module Dominance
        module_function

        def compute(entry, blocks)
          predecessors = blocks.to_h { |block| [block.id, []] }
          add_predecessors(blocks, predecessors)
          all = blocks.map(&:id)
          result = blocks.to_h { |block| [block.id, block.id == entry ? [entry] : all.dup] }
          iterate(entry, blocks, predecessors, all, result)
          result.transform_values { |ids| ids.to_a.sort.freeze }.freeze
        end

        def add_predecessors(blocks, predecessors)
          blocks.each { |block| block.successors.each { |edge| predecessors.fetch(edge.target) << block.id } }
        end

        def iterate(entry, blocks, predecessors, all, result)
          loop do
            changed = blocks.map { |block| update_block(block, entry, predecessors, all, result) }.any?
            break unless changed
          end
        end

        def update_block(block, entry, predecessors, all, result)
          return false if block.id == entry

          incoming = predecessors.fetch(block.id)
          return false if incoming.empty?

          next_set = intersect_dominators(incoming, all, result) | [block.id]
          changed = next_set != result[block.id]
          result[block.id] = next_set
          changed
        end

        def intersect_dominators(incoming, all, result)
          incoming.map { |id| result.fetch(id) }.reduce(all.dup) { |set, ids| set & ids }
        end
      end

      # Mutable construction API shared by AST lowering and future parser actions.
      class Builder
        MutableBlock = Struct.new(:id, :operations, :terminator, :successors, keyword_init: true)

        def initialize
          @blocks = []
          @state_versions = Hash.new(0)
          @state_tokens = {}
        end

        def block
          value = MutableBlock.new(id: @blocks.length, operations: [], terminator: nil, successors: [])
          @blocks << value
          value
        end

        def append(block, opcode, operand: nil, effects: [])
          reads = state_domains(effects, :reads)
          writes = state_domains(effects, :writes)
          state_in = reads.to_h { |domain| [domain, token_for(domain)] }
          state_out = writes.to_h do |domain|
            @state_versions[domain] += 1
            token = StateToken.new(domain: domain, version: @state_versions[domain])
            @state_tokens[domain] = token
            [domain, token]
          end
          block.operations << Operation.new(opcode: opcode, operand: operand, effects: effects,
                                            state_in: state_in, state_out: state_out)
          block
        end

        def terminate(block, opcode)
          block.terminator = Terminator.new(opcode: opcode)
          block
        end

        def connect(source, target, kind: :flow, priority: 0)
          source.successors << Edge.new(target: target.id, kind: kind, priority: priority)
          source
        end

        def finish(entry:, exit:)
          immutable = @blocks.map do |block|
            terminator = block.terminator || Terminator.new(opcode: block == exit ? :return : :jump)
            Block.new(id: block.id, operations: block.operations, terminator: terminator,
                      successors: block.successors)
          end
          Graph.new(entry: entry.id, exit: exit.id, blocks: immutable)
        end

        private

        EFFECT_STATE_DOMAINS = {
          reads: {
            capture: %i[cursor captures], assertion: %i[cursor captures checkpoints],
            choice: %i[cursor captures], repeat: %i[cursor], cut: %i[checkpoints],
            capture_read: %i[captures], call: %i[cursor captures]
          },
          writes: {
            capture: %i[captures], assertion: %i[captures checkpoints], choice: %i[checkpoints],
            repeat: %i[repeats checkpoints], cut: %i[cuts checkpoints], call: %i[calls checkpoints]
          }
        }.freeze

        def state_domains(effects, direction)
          domains = effects.flat_map { |effect| EFFECT_STATE_DOMAINS.fetch(direction).fetch(effect, %i[cursor]) }
          domains.uniq
        end

        def token_for(domain)
          @state_tokens[domain] ||= StateToken.new(domain: domain, version: @state_versions[domain])
        end
      end

      # Lowers structural regex control into an ordered CFG without deciding matches.
      class Lowerer
        Fragment = Struct.new(:entry, :exit, keyword_init: true)

        EFFECTS = {
          AST::Group => %i[capture],
          AST::Assertion => %i[assertion capture choice],
          AST::AtomicGroup => %i[choice cut],
          AST::Quantifier => %i[choice repeat],
          AST::Backreference => %i[capture_read],
          AST::Conditional => %i[capture_read choice],
          AST::SubexpressionCall => %i[call choice capture],
          AST::Absence => %i[choice capture]
        }.freeze

        OPCODES = {
          AST::Literal => :match_literal,
          AST::CharacterClass => :match_class,
          AST::Escape => :match_escape,
          AST::Property => :match_property,
          AST::Any => :match_any,
          AST::Anchor => :test_anchor,
          AST::Group => :match_group,
          AST::Assertion => :match_assertion,
          AST::OptionGroup => :match_option_group,
          AST::AtomicGroup => :match_atomic_group,
          AST::Quantifier => :match_quantifier,
          AST::Backreference => :match_backreference,
          AST::Conditional => :match_conditional,
          AST::SubexpressionCall => :match_subexpression_call,
          AST::Absence => :match_absence
        }.freeze

        def call(ast)
          @builder = Builder.new
          fragment = lower(ast)
          @builder.terminate(fragment.exit, :return)
          @builder.finish(entry: fragment.entry, exit: fragment.exit)
        end

        private

        def lower(node)
          return lower_sequence(node) if node.is_a?(AST::Sequence)
          return lower_alternation(node) if node.is_a?(AST::Alternation)

          lower_operation(node)
        end

        def lower_sequence(node)
          return empty_fragment if node.parts.empty?
          return lower_coalesced_sequence(node) if coalescible_sequence?(node)

          fragments = node.parts.map { |part| lower(part) }
          connect_sequence(fragments)
          Fragment.new(entry: fragments.first.entry, exit: fragments.last.exit)
        end

        def lower_coalesced_sequence(node)
          block = @builder.block
          node.parts.each { |part| append_operation(block, part) }
          Fragment.new(entry: block, exit: block)
        end

        def coalescible_sequence?(node)
          node.parts.none? { |part| part.is_a?(AST::Sequence) || part.is_a?(AST::Alternation) }
        end

        def connect_sequence(fragments)
          fragments.each_cons(2) do |left, right|
            @builder.terminate(left.exit, :jump)
            @builder.connect(left.exit, right.entry)
          end
        end

        def lower_alternation(node)
          choice = @builder.block
          merge = @builder.block
          @builder.terminate(choice, :choice)
          node.branches.each_with_index do |branch, priority|
            fragment = lower(branch)
            @builder.connect(choice, fragment.entry, kind: :alternative, priority: priority)
            @builder.terminate(fragment.exit, :jump)
            @builder.connect(fragment.exit, merge)
          end
          Fragment.new(entry: choice, exit: merge)
        end

        def lower_operation(node)
          block = @builder.block
          append_operation(block, node)
          Fragment.new(entry: block, exit: block)
        end

        def append_operation(block, node)
          opcode = OPCODES[node.class]
          raise CodegenError, "unsupported CFG node #{node.class}" unless opcode

          @builder.append(block, opcode, operand: node, effects: EFFECTS.fetch(node.class, []))
        end

        def empty_fragment
          block = @builder.block
          @builder.append(block, :epsilon)
          Fragment.new(entry: block, exit: block)
        end
      end
    end
  end
end
