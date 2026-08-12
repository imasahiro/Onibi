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
          sources.drop(1).each do |source|
            allowed = source.candidate_positions(input, position).to_h { |candidate| [candidate, true] }
            candidates.select! { |candidate| allowed[candidate] }
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
    end
  end
end
