# frozen_string_literal: true

module Onibi
  module Codegen
    # Immutable control-flow representation used between parsing and Ruby emission.
    module CFG
      Operation = Struct.new(:opcode, :operand, :effects, keyword_init: true) do
        def initialize(opcode:, operand: nil, effects: [])
          super(opcode: opcode, operand: operand, effects: effects.dup.freeze)
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

      Block = Struct.new(:id, :operations, :terminator, :successors, keyword_init: true) do
        def initialize(id:, operations:, terminator:, successors:)
          super(id: id, operations: operations.freeze, terminator: terminator, successors: successors.freeze)
          freeze
        end
      end

      Graph = Struct.new(:entry, :exit, :blocks, keyword_init: true) do
        def initialize(entry:, exit:, blocks:)
          super(entry: entry, exit: exit, blocks: blocks.freeze)
          freeze
        end

        def operations
          blocks.flat_map(&:operations).freeze
        end
      end

      # Mutable construction API shared by AST lowering and future parser actions.
      class Builder
        MutableBlock = Struct.new(:id, :operations, :terminator, :successors, keyword_init: true)

        def initialize
          @blocks = []
        end

        def block
          value = MutableBlock.new(id: @blocks.length, operations: [], terminator: nil, successors: [])
          @blocks << value
          value
        end

        def append(block, opcode, operand: nil, effects: [])
          block.operations << Operation.new(opcode: opcode, operand: operand, effects: effects)
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

          fragments = node.parts.map { |part| lower(part) }
          connect_sequence(fragments)
          Fragment.new(entry: fragments.first.entry, exit: fragments.last.exit)
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
          opcode = OPCODES[node.class]
          raise CodegenError, "unsupported CFG node #{node.class}" unless opcode

          block = @builder.block
          @builder.append(block, opcode, operand: node, effects: EFFECTS.fetch(node.class, []))
          Fragment.new(entry: block, exit: block)
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
