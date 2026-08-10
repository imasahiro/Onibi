# frozen_string_literal: true

require_relative "onibi/version"

module Onibi
  class Error < StandardError; end

  # Minimal public regexp facade used while the engine is bootstrapped.
  class Regexp
    def initialize(pattern)
      @pattern = String(pattern)
    end

    def match?(input)
      String(input).include?(@pattern)
    end
  end
end
