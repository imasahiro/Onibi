# frozen_string_literal: true

require_relative "onibi/version"
require_relative "onibi/regexp_options"
require_relative "onibi/unicode_property_scripts"
require_relative "onibi/unicode_property_categories"
require_relative "onibi/unicode_properties"
require_relative "onibi/lexer_classes"
require_relative "onibi/lexer_comments"
require_relative "onibi/lexer_escapes"
require_relative "onibi/lexer"
require_relative "onibi/character_predicates"
require_relative "onibi/class_predicates"
require_relative "onibi/class_predicates_posix"
require_relative "onibi/ast"
require_relative "parser_widths"
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
require_relative "onibi/matching_result"
require_relative "onibi/ast_matcher_dispatch"
require_relative "onibi/ast_matcher"
require_relative "onibi/capture_matcher_dispatch"
require_relative "onibi/capture_matcher_atoms"
require_relative "onibi/capture_matcher_subexpressions"
require_relative "onibi/capture_matcher_absence"
require_relative "onibi/capture_matcher_linebreaks"
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
    include RegexpOptions

    IGNORECASE = 1
    MULTILINE = 4
    FIXEDENCODING = 16
    NOENCODING = 32

    @dfa_memory_budget = 1

    class << self
      attr_accessor :dfa_memory_budget
    end

    def self.compile(pattern, options = nil)
      new(pattern, options)
    end

    def initialize(pattern, options = nil)
      validate_pattern_type!(pattern)
      validate_pattern_encoding!(pattern)
      normalized_options = normalize_options(options)
      validate_noencoding_pattern!(pattern, normalized_options)
      validate_pattern_syntax!(pattern, normalized_options)
      @pattern = pattern
      @options = normalized_options
      @public_options = options.is_a?(Integer) ? options : normalized_options
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
      @public_options.is_a?(Array) ? @public_options.dup : @public_options
    end

    private

    def validate_pattern_type!(pattern)
      return if pattern.is_a?(String)

      raise TypeError, "no implicit conversion of #{pattern.class} into String"
    end

    def validate_pattern_encoding!(pattern)
      return if pattern.valid_encoding?

      raise RegexpError, "invalid byte sequence in #{pattern.encoding}"
    end

    def matching_result(input)
      MatchingResult.call(@ast, @bytecode, @pattern, @options, input)
    end

    def validate_pattern_syntax!(pattern, options)
      tokens = Lexer.new(pattern).tokens
      binary_pattern = pattern.encoding == Encoding::ASCII_8BIT || options.include?("noencoding")
      if binary_pattern && tokens.any? { |token| token.type == :property }
        raise RegexpError, "Unicode properties require a text encoding"
      end

      tokens
    end

    def validate_encoding!(input)
      raise ArgumentError, "invalid byte sequence in #{input.encoding}" unless input.valid_encoding?

      return if @options.include?("noencoding") && input.encoding == Encoding::ASCII_8BIT
      return if @pattern.ascii_only?
      return if @pattern.encoding == input.encoding

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
