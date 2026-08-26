# frozen_string_literal: true

module Onibi
  module Automata
    Tag = Struct.new(:kind, :value, keyword_init: true) do
      def initialize(kind:, value: nil)
        super
        freeze
      end
    end

    TaggedTransition = Struct.new(:from, :to, :operation, :tags, keyword_init: true) do
      def initialize(from:, to:, operation:, tags: [])
        super(from: from, to: to, operation: operation, tags: tags.freeze)
        freeze
      end
    end

    # Tagged automata retain state effects that ordinary DFA determinization
    # must not merge, such as capture and call boundaries.
    class TaggedTNFA
      attr_reader :tnfa, :transitions, :start_positions, :accept_positions

      def self.from_tnfa(tnfa)
        new(tnfa)
      end

      def initialize(tnfa)
        @tnfa = tnfa
        @transitions = tnfa.transitions.map do |transition|
          TaggedTransition.new(from: transition.from, to: transition.to,
                               operation: transition.operation,
                               tags: tags_for(transition.operation))
        end.freeze
        @start_positions = tnfa.start_positions
        @accept_positions = tnfa.accept_positions
        freeze
      end

      private

      def tags_for(operation)
        operation.effects.filter_map do |effect|
          Tag.new(kind: effect, value: operation.operand)
        end
      end
    end

    class TaggedDFA
      attr_reader :dfa, :states, :transitions, :start_state

      def self.from_tagged_tnfa(tagged_tnfa)
        new(tagged_tnfa)
      end

      def initialize(tagged_tnfa)
        @dfa = DFA.from_tnfa(tagged_tnfa.tnfa)
        @states = @dfa.states
        @start_state = @dfa.start_state
        # Keep the source state in the lookup key.  The same operation can
        # occur in several states, but its capture effects are local to the
        # edge that carries them.
        @transitions = @dfa.transitions.transform_keys do |(source, label)|
          state = @states.fetch(source)
          sources = state.positions.empty? ? [:start] : state.positions
          tagged = tagged_tnfa.transitions.select do |edge|
            sources.include?(edge.from) &&
              edge.operation.opcode == label[0] && edge.operation.operand == label[1]
          end
          [source, label, tagged ? tagged.flat_map(&:tags).freeze : []]
        end.freeze
        freeze
      end
    end

    Position = Struct.new(:id, :operation, keyword_init: true) { def initialize(**kwargs) = super(**kwargs).freeze }
    Transition = Struct.new(:from, :to, :operation, keyword_init: true) { def initialize(**kwargs) = super(**kwargs).freeze }

    class GlushkovTNFA
      attr_reader :positions, :transitions, :start_positions, :accept_positions

      def self.from_cfg(cfg)
        new(cfg)
      end

      def initialize(cfg)
        @cfg_blocks = cfg.blocks
        @positions = cfg.blocks.flat_map(&:operations).each_with_index.map do |operation, id|
          Position.new(id: id, operation: operation)
        end.freeze
        @by_block = cfg.blocks.to_h { |block| [block.id, positions_for(block)] }
        @transitions = build_transitions(cfg).freeze
        @start_positions = entry_positions(cfg.entry).map(&:id).freeze
        @accept_positions = accepting_positions(cfg).map(&:id).freeze
      end

      private

      def positions_for(block)
        offset = cfg_position_offset(block)
        @positions[offset, block.operations.length]
      end

      def cfg_position_offset(block)
        @offsets ||= block_offsets
        @offsets.fetch(block.id)
      end

      def block_offsets
        # Blocks are immutable and retain construction order.
        result = {}
        offset = 0
        @cfg_blocks.each do |block|
          result[block.id] = offset
          offset += block.operations.length
        end
        result
      end

      def build_transitions(cfg)
        transitions = entry_positions(cfg.entry).map do |position|
          Transition.new(from: :start, to: position.id, operation: position.operation)
        end
        cfg.blocks.each do |block|
          current = positions_for(block)
          current.each_cons(2) { |from, to| transitions << Transition.new(from: from.id, to: to.id, operation: to.operation) }
          last = current.last
          next unless last

          block.successors.each do |edge|
            next_positions(edge.target).each do |target|
              transitions << Transition.new(from: last.id, to: target.id, operation: target.operation)
            end
          end
        end
        transitions
      end

      def entry_positions(block_id, visited = {})
        return [] if visited[block_id]

        visited[block_id] = true
        positions = @by_block.fetch(block_id)
        return positions.first(1) unless positions.empty?

        block_for(block_id).successors.flat_map { |edge| entry_positions(edge.target, visited) }.uniq
      end

      def next_positions(block_id, visited = {})
        return [] if visited[block_id]

        visited[block_id] = true
        positions = @by_block.fetch(block_id)
        return positions.first(1) unless positions.empty?

        block_for(block_id).successors.flat_map { |edge| next_positions(edge.target, visited) }.uniq
      end

      def accepting_positions(cfg)
        can_reach_exit = reachable_to_exit(cfg).freeze
        @cfg_blocks.filter_map do |block|
          positions = @by_block.fetch(block.id)
          positions.last if positions.any? && can_reach_exit.include?(block.id)
        end
      end

      def reachable_to_exit(cfg)
        result = { cfg.exit => true }
        loop do
          changed = false
          cfg.blocks.each do |block|
            next if result[block.id]

            if block.successors.any? { |edge| result[edge.target] }
              result[block.id] = true
              changed = true
            end
          end
          break result.keys unless changed
        end
      end

      def block_for(block_id)
        @cfg_blocks.find { |block| block.id == block_id }
      end
    end

    State = Struct.new(:id, :positions, :accepting, keyword_init: true) do
      def initialize(**kwargs) = super(**kwargs.merge(positions: kwargs.fetch(:positions).freeze)).freeze
    end

    class DFA
      attr_reader :states, :transitions, :start_state, :tnfa

      def self.from_tnfa(tnfa)
        new(tnfa)
      end

      def initialize(tnfa, state_limit: nil)
        @tnfa = tnfa
        @state_limit = state_limit
        build
      end

      private

      def build
        @states = []
        pending = []
        queue = [[]]
        seen = {}
        until queue.empty?
          subset = queue.shift
          key = subset.freeze
          next if seen.key?(key)
          break if @state_limit && @states.length >= @state_limit

          state = State.new(id: @states.length, positions: subset,
                            accepting: (subset & tnfa.accept_positions).any?)
          seen[key] = state
          @states << state
          outgoing(subset).each do |label, target|
            target = target.sort.freeze
            pending << [[state.id, label], target]
            queue << target unless seen.key?(target)
          end
        end
        state_ids = @states.to_h { |state| [state.positions, state.id] }
        @transitions = pending.each_with_object({}) do |(key, target), result|
          target_id = state_ids[target]
          result[key] = target_id if target_id
        end
        @start_state = @states.first
        @states.freeze
        @transitions.freeze
      end

      def outgoing(subset)
        tnfa.transitions.each_with_object(Hash.new { |h, k| h[k] = [] }) do |edge, result|
          next unless subset.empty? ? edge.from == :start : subset.include?(edge.from)

          result[label(edge.operation)] << edge.to
        end.transform_values(&:uniq)
      end

      def label(operation)
        [operation.opcode, operation.operand]
      end
    end

    class PartialDFA < DFA
      def self.from_tnfa(tnfa, state_limit:)
        new(tnfa, state_limit: state_limit)
      end

      def partial?
        states.length < full_state_count
      end

      private

      def full_state_count
        @full_state_count ||= DFA.new(tnfa).states.length
      end
    end
  end
end
