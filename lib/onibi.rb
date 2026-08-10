# frozen_string_literal: true

require_relative "onibi/version"
require_relative "onibi/lexer"
require_relative "onibi/character_predicates"
require_relative "onibi/ast"
require_relative "onibi/parser"
require_relative "onibi/bytecode"
require_relative "onibi/alternation_compiler"
require_relative "onibi/compiler"
require_relative "onibi/virtual_machine"
require_relative "onibi/ast_matcher_dispatch"
require_relative "onibi/ast_matcher"
require_relative "onibi/match_data"
require_relative "onibi/dfa"

module Onibi
  class Error < StandardError; end
  class RegexpError < Error; end

  # Minimal public regexp facade used while the engine is bootstrapped.
  class Regexp
    @dfa_memory_budget = 1

    class << self
      attr_accessor :dfa_memory_budget
    end

    def self.compile(pattern, options = nil)
      new(pattern, options)
    end

    def initialize(pattern, options = nil)
      validate_pattern_type!(pattern)
      normalized_options = normalize_options(options)
      validate_pattern_syntax!(pattern)
      @pattern = pattern
      @options = normalized_options
      @ast = Parser.new(pattern).parse
      @bytecode = Compiler.new(@ast).compile
    end

    def match?(input)
      raise TypeError, "no implicit conversion of #{input.class} into String" unless input.is_a?(String)

      validate_encoding!(input)

      result = VirtualMachine.new(@bytecode, @options).match?(input)
      result ||= (@pattern.include?("|") || @pattern.include?("(")) && AstMatcher.new(@ast, @options).match?(input)

      dfa_specialization
      result
    end

    def match(input)
      raise TypeError, "no implicit conversion of #{input.class} into String" unless input.is_a?(String)

      validate_encoding!(input)

      span = AstMatcher.new(@ast, @options).match_span(input)
      dfa_specialization
      return nil unless span

      characters = input.chars
      full_match = characters[span[0]...span[1]].join
      MatchData.new(full_match, [], [span])
    end

    def options
      @options.dup
    end

    private

    def validate_pattern_type!(pattern)
      return if pattern.is_a?(String)

      raise TypeError, "no implicit conversion of #{pattern.class} into String"
    end

    def normalize_options(options)
      normalized_options = options || []
      valid_options = normalized_options.is_a?(Array) && normalized_options.all? do |option|
        %w[ignorecase multiline].include?(option)
      end
      raise ArgumentError, "invalid options" unless valid_options

      normalized_options
    end

    def validate_pattern_syntax!(pattern)
      return if pattern.count("[") == pattern.count("]")

      raise RegexpError, "malformed character class"
    end

    def validate_encoding!(input)
      return if @pattern.encoding == input.encoding
      return if @pattern.ascii_only? && input.ascii_only?

      raise Encoding::CompatibilityError, "incompatible encoding regexp match"
    end

    def dfa_specialization
      return if self.class.dfa_memory_budget.zero?

      @dfa_specialization ||= DfaSpecialization.new(@ast)
    end
  end
end
