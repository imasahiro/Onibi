# frozen_string_literal: true

require_relative "onibi/version"
require_relative "onibi/lexer"
require_relative "onibi/ast"
require_relative "onibi/parser"
require_relative "onibi/bytecode"
require_relative "onibi/compiler"
require_relative "onibi/virtual_machine"
require_relative "onibi/ast_matcher"

module Onibi
  class Error < StandardError; end
  class RegexpError < Error; end

  # Minimal public regexp facade used while the engine is bootstrapped.
  class Regexp
    # rubocop:disable Metrics/AbcSize
    def initialize(pattern, options = nil)
      raise TypeError, "no implicit conversion of #{pattern.class} into String" unless pattern.is_a?(String)

      normalized_options = options || []
      valid_options = normalized_options.is_a?(Array) && normalized_options.all? do |option|
        %w[ignorecase multiline].include?(option)
      end
      raise ArgumentError, "invalid options" unless valid_options
      raise RegexpError, "malformed character class" unless pattern.count("[") == pattern.count("]")

      @pattern = pattern
      @options = normalized_options
      @ast = Parser.new(pattern).parse
      @bytecode = Compiler.new(@ast).compile
    end
    # rubocop:enable Metrics/AbcSize

    def match?(input)
      raise TypeError, "no implicit conversion of #{input.class} into String" unless input.is_a?(String)

      return true if VirtualMachine.new(@bytecode, @options).match?(input)
      return false unless @pattern.include?("|") || @pattern.include?("(")

      AstMatcher.new(@ast, @options).match?(input)
    end
  end
end
