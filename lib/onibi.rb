# frozen_string_literal: true

require_relative "onibi/version"
require_relative "onibi/lexer"
require_relative "onibi/ast"
require_relative "onibi/parser"

module Onibi
  class Error < StandardError; end
  class RegexpError < Error; end

  # Minimal public regexp facade used while the engine is bootstrapped.
  class Regexp
    def initialize(pattern, options = nil)
      raise TypeError, "no implicit conversion of #{pattern.class} into String" unless pattern.is_a?(String)
      raise ArgumentError, "invalid options" unless options.nil?
      raise RegexpError, "malformed character class" unless pattern.count("[") == pattern.count("]")

      @pattern = pattern
      @ast = Parser.new(pattern).parse
    end

    def match?(input)
      raise TypeError, "no implicit conversion of #{input.class} into String" unless input.is_a?(String)

      input.include?(@pattern)
    end
  end
end
