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

          candidates = unique_ordered(sources.first.candidate_positions(input, position))
          return [] if candidates.empty?

          sources.drop(1).each do |source|
            allowed = source.candidate_positions(input, position).to_h { |candidate| [candidate, true] }
            candidates.select! { |candidate| allowed[candidate] }
            return [] if candidates.empty?
          end
          candidates
        end

        def preserves_order?
          sources.all?(&:preserves_order?)
        end

        private

        def unique_ordered(candidates)
          seen = {}
          candidates.each_with_object([]) do |candidate, result|
            next if seen[candidate]

            seen[candidate] = true
            result << candidate
          end
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
          streams = sources.filter_map do |source|
            next unless source.eligible?(input, position)

            source.candidate_positions(input, position)
          end
          merge_streams(streams)
        end

        def preserves_order?
          sources.all?(&:preserves_order?)
        end

        private

        def merge_streams(streams)
          return [] if streams.empty?
          return streams.first if streams.length == 1

          streams.flatten.uniq.sort!
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

        def preserves_order?
          true
        end
      end
    end
  end
end
