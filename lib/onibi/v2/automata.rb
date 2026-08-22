# frozen_string_literal: true

module Onibi
  module V2
    module Automata
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
          @start_positions = first_position(cfg.entry).then { |position| position ? [position.id] : [] }.freeze
          @accept_positions = last_position(cfg.exit).then { |position| position ? [position.id] : [] }.freeze
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
          transitions = []
          cfg.blocks.each do |block|
            current = positions_for(block)
            current.each_cons(2) { |from, to| transitions << Transition.new(from: from.id, to: to.id, operation: to.operation) }
            last = current.last
            next unless last

            block.successors.each do |edge|
              target = first_position(edge.target)
              transitions << Transition.new(from: last.id, to: target.id, operation: target.operation) if target
            end
          end
          transitions
        end

        def first_position(block_id, visited = {})
          return if visited[block_id]

          visited[block_id] = true
          block = @cfg_blocks.find { |candidate| candidate.id == block_id }
          return @by_block.fetch(block_id).first if @by_block.fetch(block_id).any?

          block.successors.each do |edge|
            position = first_position(edge.target, visited)
            return position if position
          end
          nil
        end

        def last_position(block_id, visited = {})
          return if visited[block_id]

          visited[block_id] = true
          positions = @by_block.fetch(block_id)
          return positions.last if positions.any?

          predecessors = @cfg_blocks.select { |block| block.successors.any? { |edge| edge.target == block_id } }
          predecessors.reverse_each do |block|
            position = last_position(block.id, visited)
            return position if position
          end
          nil
        end
      end

      State = Struct.new(:id, :positions, :accepting, keyword_init: true) do
        def initialize(**kwargs) = super(**kwargs.merge(positions: kwargs.fetch(:positions).freeze)).freeze
      end

      class DFA
        attr_reader :states, :transitions, :start_state

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
          @transitions = {}
          queue = [tnfa.start_positions.sort]
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
              @transitions[[state.id, label]] = target
              queue << target unless seen.key?(target)
            end
          end
          @start_state = @states.first
          @states.freeze
          @transitions.freeze
        end

        def outgoing(subset)
          tnfa.transitions.each_with_object(Hash.new { |h, k| h[k] = [] }) do |edge, result|
            next unless subset.include?(edge.from)

            result[label(edge.operation)] << edge.to
          end.transform_values(&:uniq)
        end

        def label(operation)
          [operation.opcode, operation.operand]
        end

        attr_reader :tnfa
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
end
