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
    end
  end
end
