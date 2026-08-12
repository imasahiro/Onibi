# frozen_string_literal: true

module Onibi
  module Codegen
    # Internal protocol for ordered candidate-start generators.
    module CandidateSource
      def eligible?(input, position)
        raise NotImplementedError
      end

      def candidate_positions(input, position)
        raise NotImplementedError
      end

      # Streams candidates without requiring a materialized result array.
      # Implementations with an efficient scanner should override this method;
      # the fallback preserves compatibility for small/custom sources.
      def each_candidate(input, position, &block)
        return enum_for(__method__, input, position) unless block_given?

        candidate_positions(input, position).each(&block)
      end

      def preserves_order?
        true
      end

      # Combines necessary candidate sources while retaining leftmost order.
      class Intersection
        include CandidateSource

        attr_reader :sources

        def initialize(sources)
          raise ArgumentError, "at least one candidate source is required" if sources.empty?

          @sources = sources.dup.freeze
          freeze
        end

        def eligible?(input, position)
          sources.all? { |source| source.eligible?(input, position) }
        end

        def candidate_positions(input, position)
          return [] unless eligible?(input, position)
          return sources.first.candidate_positions(input, position) if sources.length == 1

          candidates = []
          each_candidate(input, position) { |candidate| candidates << candidate }
          candidates
        end

        def each_candidate(input, position, &block)
          return enum_for(__method__, input, position) unless block_given?
          return unless eligible?(input, position)

          first_stream = sources.first.each_candidate(input, position).to_enum
          candidate = next_value(first_stream)
          return unless candidate

          other_streams = sources.drop(1).map do |source|
            source.each_candidate(input, position).to_enum
          end
          emit_intersection(first_stream, other_streams, candidate, &block)
        end

        def preserves_order?
          sources.all?(&:preserves_order?)
        end

        private

        def emit_intersection(first_stream, other_streams, candidate)
          others = other_streams.map { |stream| next_value(stream) }
          previous = nil
          while candidate
            yield candidate if matching_candidate?(candidate, other_streams, others) && candidate != previous
            previous = candidate
            candidate = next_value(first_stream)
          end
        end

        def matching_candidate?(candidate, streams, current)
          current.each_with_index do |value, index|
            value = next_value(streams[index]) while value && value < candidate
            current[index] = value
            return false unless value == candidate
          end
          true
        end

        def next_value(stream)
          stream.next
        rescue StopIteration
          nil
        end
      end

      # Combines alternative candidate sources while retaining leftmost order.
      class Union
        include CandidateSource

        attr_reader :sources

        def initialize(sources)
          raise ArgumentError, "at least one candidate source is required" if sources.empty?

          @sources = sources.dup.freeze
          freeze
        end

        def eligible?(input, position)
          sources.any? { |source| source.eligible?(input, position) }
        end

        def candidate_positions(input, position)
          return [] unless eligible?(input, position)
          return sources.first.candidate_positions(input, position) if sources.length == 1

          candidates = []
          each_candidate(input, position) { |candidate| candidates << candidate }
          candidates
        end

        def each_candidate(input, position, &block)
          return enum_for(__method__, input, position) unless block_given?

          streams = eligible_streams(input, position)
          merge_streams(streams, &block)
        end

        def preserves_order?
          sources.all?(&:preserves_order?)
        end

        private

        def merge_streams(streams)
          current = streams.map { |stream| next_value(stream) }
          previous = nil
          loop do
            available = current.compact
            break if available.empty?

            candidate = available.min
            yield candidate if candidate != previous
            previous = candidate
            advance_streams(current, streams, candidate)
          end
        end

        def advance_streams(current, streams, candidate)
          current.each_with_index do |value, index|
            current[index] = next_value(streams[index]) if value == candidate
          end
        end

        def eligible_streams(input, position)
          sources.filter_map do |source|
            source.each_candidate(input, position).to_enum if source.eligible?(input, position)
          end
        end

        def next_value(stream)
          stream.next
        rescue StopIteration
          nil
        end
      end

      # Finds candidate starts for one literal with an optional start offset.
      class Literal
        include CandidateSource

        attr_reader :value, :offset

        def initialize(value, offset: 0)
          @value = value.dup.freeze
          @offset = offset
          freeze
        end

        def eligible?(input, position)
          input.is_a?(String) && position.is_a?(Integer) && position >= 0
        end

        def candidate_positions(input, position)
          return [] unless eligible?(input, position)

          starts = []
          cursor = position
          while (found = input.index(value, cursor))
            start = found - offset
            starts << start if start >= position
            cursor = found + 1
          end
          starts
        end

        def each_candidate(input, position)
          return enum_for(__method__, input, position) unless block_given?
          return unless eligible?(input, position)

          cursor = position
          while (found = input.index(value, cursor))
            start = found - offset
            yield start if start >= position
            cursor = found + 1
          end
        end

        def preserves_order?
          true
        end
      end

      # Coordinates two literal event streams separated by a bounded gap.
      class BoundedLiteralChain
        include CandidateSource

        attr_reader :left, :right, :minimum_gap, :maximum_gap

        def initialize(left, right, minimum_gap:, maximum_gap:)
          raise ArgumentError, "literals must not be empty" if left.empty? || right.empty?
          raise ArgumentError, "invalid gap bounds" if minimum_gap.negative? || maximum_gap < minimum_gap

          @left = left.dup.freeze
          @right = right.dup.freeze
          @minimum_gap = minimum_gap
          @maximum_gap = maximum_gap
          freeze
        end

        def eligible?(input, position)
          input.is_a?(String) && input.ascii_only? && position.is_a?(Integer) && position >= 0
        end

        def candidate_positions(input, position)
          candidates = []
          each_candidate(input, position) { |candidate| candidates << candidate }
          candidates
        end

        def each_candidate(input, position, &block)
          return enum_for(__method__, input, position) unless block
          return unless eligible?(input, position)

          scan_candidates(input, position, &block)
        end

        private

        def scan_candidates(input, position)
          left_cursor = position
          right_event = nil
          while (left_event = input.index(left, left_cursor))
            earliest = gap_boundary(left_event, minimum_gap)
            right_event = next_right_event(input, right_event, earliest)
            yield left_event if right_event && right_event <= gap_boundary(left_event, maximum_gap)
            left_cursor = left_event + 1
          end
        end

        def gap_boundary(left_event, gap)
          left_event + left.bytesize + gap
        end

        def next_right_event(input, current, earliest)
          return current if current && current >= earliest

          input.index(right, earliest)
        end
      end
    end
  end
end
