# frozen_string_literal: true

require_relative "onibi/version"
require_relative "onibi/regexp_options"
require_relative "onibi/regexp_utilities"
require_relative "onibi/regexp_constructor_patterns"
require_relative "onibi/regexp_encoding_validation"
require_relative "onibi/regexp_object_semantics"
require_relative "onibi/unicode_property_scripts"
require_relative "onibi/unicode_property_categories"
require_relative "onibi/unicode_properties"
require_relative "onibi/lexer_classes"
require_relative "onibi/lexer_option_groups"
require_relative "onibi/lexer_comments"
require_relative "onibi/lexer_extended_mode"
require_relative "onibi/lexer_dispatch"
require_relative "onibi/lexer_token_stream"
require_relative "onibi/lexer_escapes"
require_relative "onibi/lexer"
require_relative "onibi/character_predicates"
require_relative "onibi/class_predicates"
require_relative "onibi/class_predicates_posix"
require_relative "onibi/ast"
require_relative "parser_widths"
require_relative "parser_assertions"
require_relative "onibi/parser_quantifiers"
require_relative "onibi/parser_option_groups"
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
require_relative "onibi/option_group_matchers"
require_relative "onibi/ast_matcher"
require_relative "onibi/capture_matcher_dispatch"
require_relative "onibi/capture_matcher_atoms"
require_relative "onibi/capture_matcher_subexpressions"
require_relative "onibi/capture_matcher_absence"
require_relative "onibi/capture_matcher_linebreaks"
require_relative "onibi/capture_matcher"
require_relative "onibi/capture_name_collector"
require_relative "onibi/backreference_lexer"
require_relative "onibi/match_data_destructuring"
require_relative "onibi/match_data_offsets"
require_relative "onibi/match_data"
require_relative "onibi/dfa"

module Onibi
  class Error < StandardError; end
  class RegexpError < Error; end

  # Minimal public regexp facade used while the engine is bootstrapped.
  class Regexp
    extend RegexpUtilities
    include RegexpOptions
    include RegexpConstructorPatterns
    include RegexpEncodingValidation
    include RegexpObjectSemantics

    IGNORECASE = 1
    EXTENDED = 2
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
      pattern, options = normalize_constructor_pattern(pattern, options)
      pattern, normalized_options = prepare_constructor_pattern(pattern, options)
      @ast = Parser.new(pattern, normalized_options).parse
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

      context = MatchData::Context.new(input, self)
      MatchData.new(*match_data_arguments(details, input), CaptureNameCollector.call(@ast), context)
    end

    define_method([61, 126].pack("C*")) do |input|
      details = match(input)
      details&.begin(0)
    end

    def ===(input)
      match?(input)
    end

    def ~
      input = eval("$_", TOPLEVEL_BINDING, __FILE__, __LINE__)
      send([61, 126].pack("C*"), input)
    end

    def options
      @public_options
    end

    def source
      @source_pattern.dup
    end

    def casefold?
      @options.include?("ignorecase")
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
      tokens = Lexer.new(pattern, options).tokens
      binary_pattern = pattern.encoding == Encoding::ASCII_8BIT || options.include?("noencoding")
      if binary_pattern && tokens.any? { |token| token.type == :property }
        raise RegexpError, "Unicode properties require a text encoding"
      end

      tokens
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
