# frozen_string_literal: true

require_relative "onibi/version"

module Onibi
  class Error < StandardError; end

  class Regexp
    def initialize(pattern)
      @pattern = String(pattern)
    end

    def match?(input)
      String(input).include?(@pattern)
    end
  end
end
