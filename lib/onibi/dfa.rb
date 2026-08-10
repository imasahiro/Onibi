# frozen_string_literal: true

module Onibi
  # Lazily published per-regexp specialization metadata.
  class DfaSpecialization
    attr_reader :ast

    def initialize(ast)
      @ast = ast
    end
  end
end
