# frozen_string_literal: true

require_relative "onibi/version"
require_relative "onibi/unicode_property_scripts"
require_relative "onibi/unicode_property_categories"
require_relative "onibi/unicode_properties"
require_relative "onibi/lexer_classes"
require_relative "onibi/lexer"
require_relative "onibi/character_predicates"
require_relative "onibi/class_predicates"
require_relative "onibi/class_predicates_posix"
require_relative "onibi/ast"
require_relative "parser_assertions"
require_relative "onibi/parser_quantifiers"
require_relative "onibi/parser"
require_relative "onibi/parser_tokens"
require_relative "onibi/bytecode"
require_relative "onibi/alternation_compiler"
require_relative "onibi/compiler_references"
require_relative "onibi/compiler_quantifiers"
require_relative "onibi/compiler"
require_relative "onibi/virtual_machine_anchors"
require_relative "onibi/virtual_machine"
require_relative "onibi/ast_matcher_dispatch"
require_relative "onibi/ast_matcher"
require_relative "onibi/capture_matcher_dispatch"
require_relative "onibi/capture_matcher_atoms"
require_relative "onibi/capture_matcher"
require_relative "onibi/capture_name_collector"
require_relative "onibi/backreference_lexer"
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

      result = matching_result(input)

      dfa_specialization
      result
    end

    def match(input)
      raise TypeError, "no implicit conversion of #{input.class} into String" unless input.is_a?(String)

      validate_encoding!(input)

      details = match_details(input)
      dfa_specialization
      return nil unless details

      MatchData.new(*match_data_arguments(details, input), CaptureNameCollector.call(@ast))
    end

    def options
      @options.dup
    end

    private

    def validate_pattern_type!(pattern)
      return if pattern.is_a?(String)

      raise TypeError, "no implicit conversion of #{pattern.class} into String"
    end

    def ast_matcher_required?
      matcher_tokens = [
        "\\R", "\\b", "\\B", "\\G", "\\p", "\\P", "(?=", "(?!", "(?<=", "(?<!", "(?>",
        "*+", "++", "?+", "*?", "+?", "??", "?("
      ]
      matcher_tokens.any? do |escape|
        @pattern.include?(escape)
      end
    end

    def matching_result(input)
      return !CaptureMatcher.new(@ast, @options).match_details(input).nil? if capture_matcher_required?

      return AstMatcher.new(@ast, @options).match?(input) if ast_matcher_required?

      result = nil
      result ||= VirtualMachine.new(@bytecode, @options).match?(input)
      result ||= (@pattern.include?("|") || @pattern.include?("(")) && AstMatcher.new(@ast, @options).match?(input)
      result
    end

    def capture_matcher_required?
      ["\\k", "\\1", "\\2", "\\3", "\\4", "\\5", "\\6", "\\7", "\\8", "\\9", "?("].any? do |escape|
        @pattern.include?(escape)
      end
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
      Lexer.new(pattern).tokens
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

    def match_details(input)
      CaptureMatcher.new(@ast, @options).match_details(input)
    end

    def match_data_arguments(details, input)
      start, finish, capture_offsets = details
      characters = input.chars
      full_match = characters[start...finish].join
      captures = capture_offsets.map { |offset| offset && characters[offset[0]...offset[1]].join }
      [full_match, captures, [[start, finish]] + capture_offsets]
    end
  end
end
