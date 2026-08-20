# frozen_string_literal: true

require_relative "onibi/version"
require_relative "onibi/regexp_options"
require_relative "onibi/regexp_utilities"
require_relative "onibi/regexp_constructor_patterns"
require_relative "onibi/regexp_encoding_validation"
require_relative "onibi/regexp_object_semantics"
require_relative "onibi/regexp_timeout"
require_relative "onibi/regexp_replacement"
require_relative "onibi/regexp_scan_gsub"
require_relative "onibi/unicode_property_scripts"
require_relative "onibi/unicode_property_categories"
require_relative "onibi/unicode_properties"
require_relative "onibi/lexer_classes"
require_relative "onibi/lexer_option_groups"
require_relative "onibi/lexer_comments"
require_relative "onibi/lexer_extended_mode"
require_relative "onibi/lexer_scoped_extended"
require_relative "onibi/lexer_extended_scopes"
require_relative "onibi/lexer_dispatch"
require_relative "onibi/lexer_token_stream"
require_relative "onibi/lexer_escapes"
require_relative "onibi/lexer"
require_relative "onibi/character_predicates"
require_relative "onibi/class_predicates"
require_relative "onibi/class_predicates_posix"
require_relative "onibi/compiled_class_predicate"
require_relative "onibi/ast"
require_relative "onibi/input_view"
require_relative "onibi/invocation_state"
require_relative "parser_widths"
require_relative "parser_assertions"
require_relative "onibi/parser_quantifiers"
require_relative "onibi/parser_option_groups"
require_relative "onibi/parser"
require_relative "onibi/parser_tokens"
require_relative "onibi/capture_name_collector"
require_relative "onibi/backreference_lexer"
require_relative "onibi/match_data_destructuring"
require_relative "onibi/match_data_offsets"
require_relative "onibi/match_data"

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
    include RegexpTimeout
    include RegexpScanGsub

    IGNORECASE = 1
    EXTENDED = 2
    MULTILINE = 4
    FIXEDENCODING = 16
    NOENCODING = 32
    HFA_ASCII_PROPERTY_TABLES = {}
    HFA_ASCII_ESCAPE_TABLES = {}

    class TimeoutError < RegexpError
    end

    def self.compile(pattern, options = nil, timeout: nil) = new(pattern, options, timeout: timeout)

    def initialize(pattern, options = nil, timeout: nil)
      pattern, options, timeout = normalize_constructor_pattern(pattern, options, timeout)
      pattern, normalized_options = prepare_constructor_pattern(pattern, options)
      @timeout = RegexpTimeout.normalize_timeout(timeout)
      tokens = validate_pattern_syntax!(pattern, normalized_options)
      @ast = HybridAutomata.normalize_ast(Parser.new(tokens).parse)
      @hfa_compilation_program_mutex = Mutex.new
    end

    def match?(input, position = 0)
      raise TypeError, "no implicit conversion of #{input.class} into String" unless input.is_a?(String)

      hfa_compilation_program
      ascii_input = input.ascii_only?
      validate_encoding!(input, ascii_input: ascii_input)
      hfa_timeout_budget_guard!(input)

      return true if hfa_empty_absence_result_safe?

      normalized_position = position.is_a?(Integer) && position.zero? ? 0 : normalize_match_position(input, position)

      if ascii_input && (spec = hfa_lookahead_literal_backreference_spec)
        return !hfa_lookahead_literal_backreference_match_result(input, normalized_position, spec).nil?
      end

      return !hfa_repeated_class_backref_match_result(input, normalized_position).nil? if ascii_input && hfa_repeated_class_backref_result_safe?

      if (class_source = hfa_unicode_class_direct_spec)
        byte_position = input.byteslice(0, normalized_position).bytesize
        return !hfa_unicode_class_direct_match_result(input, byte_position, class_source).nil?
      end
      if (spec = hfa_casefold_class_direct_spec)
        byte_position = input.byteslice(0, normalized_position).bytesize
        return !hfa_casefold_class_direct_match_result(input, byte_position, spec).nil?
      end
      if (spec = hfa_literal_capture_sequence_spec)
        byte_position = input.byteslice(0, normalized_position).bytesize
        return !hfa_literal_capture_sequence_match_result(input, byte_position, spec).nil?
      end
      if (spec = hfa_fixed_literal_backref_spec)
        return !hfa_fixed_literal_backref_match_result(input, normalized_position, spec).nil?
      end
      if (spec = hfa_repeated_literal_backref_spec)
        return !hfa_repeated_literal_backref_match_result(input, normalized_position, spec).nil?
      end
      if (spec = hfa_literal_absence_suffix_spec)
        return !hfa_literal_absence_suffix_match_result(input, normalized_position, spec).nil?
      end

      if (class_source = hfa_unicode_class_direct_spec)
        byte_position = input.byteslice(0, normalized_position).bytesize
        result = hfa_unicode_class_direct_match_result(input, byte_position, class_source)
        return hfa_match_data(result, input) if result

        return nil
      end
      if ascii_input && (spec = hfa_lookahead_literal_backreference_spec)
        result = hfa_lookahead_literal_backreference_match_result(input, normalized_position, spec)
        return hfa_match_data(result, input) if result

        return nil
      end
      if (spec = hfa_casefold_class_direct_spec)
        byte_position = input.byteslice(0, normalized_position).bytesize
        result = hfa_casefold_class_direct_match_result(input, byte_position, spec)
        return hfa_match_data(result, input) if result

        return nil
      end
      if (spec = hfa_literal_capture_sequence_spec)
        byte_position = input.byteslice(0, normalized_position).bytesize
        result = hfa_literal_capture_sequence_match_result(input, byte_position, spec)
        return hfa_match_data(result, input) if result

        return nil
      end

      if (spec = hfa_bounded_sequence_direct_spec) && (ascii_input || spec[:table].nil?)
        return !hfa_bounded_sequence_direct_match_result(input, normalized_position).nil?
      end

      if ascii_input && (spec = hfa_fixed_literal_backref_spec)
        result = hfa_fixed_literal_backref_match_result(input, normalized_position, spec)
        return hfa_match_data(result, input) if result

        return nil
      end
      if ascii_input && (spec = hfa_alternation_literal_backref_spec)
        return !hfa_alternation_literal_backref_match_result(input, normalized_position, spec).nil?
      end

      if ascii_input && (spec = hfa_repeated_literal_backref_spec)
        result = hfa_repeated_literal_backref_match_result(input, normalized_position, spec)
        return hfa_match_data(result, input) if result

        return nil
      end
      if ascii_input && (spec = hfa_literal_absence_suffix_spec)
        result = hfa_literal_absence_suffix_match_result(input, normalized_position, spec)
        return hfa_match_data(result, input) if result

        return nil
      end

      return !hfa_possessive_literal_string_match_result(input, normalized_position).nil? if ascii_input && hfa_possessive_literal_string_result_safe?

      return false if hfa_always_fails?

      return normalized_position <= input.bytesize if hfa_empty_absence_result_safe?
      if ascii_input && hfa_lookahead_alternation_backreference_spec
        return !hfa_lookahead_alternation_backreference_match_result(input, normalized_position).nil?
      end

      return !hfa_literal_absence_match_result(input, normalized_position, byte_mode: !ascii_input).nil? if hfa_literal_absence_result_safe?

      if (literal = hfa_scoped_unicode_ignorecase_literal_value)
        normalized_position = normalize_match_position(input, position)
        if hfa_unicode_simple_casefold_literal?(literal)
          folded_input = input.downcase
          folded_literal = literal.downcase
          result = !folded_input.index(folded_literal, normalized_position).nil?
          return with_timeout { result } unless timeout_unconfigured?

          return result
        end
        result = hfa_unicode_ignorecase_literal_match_result(input, normalized_position, literal)
        return with_timeout { !result.nil? } unless timeout_unconfigured?

        return !result.nil?
      end
      if !ascii_input && hfa_unicode_ignorecase_literal_result_safe?
        normalized_position = normalize_match_position(input, position)
        result = hfa_unicode_ignorecase_literal_match_result(input, normalized_position)
        return !result.nil? if timeout_unconfigured?

        return with_timeout { !result.nil? }
      end
      if !ascii_input && hfa_unicode_property_run_result_safe?
        byte_position = input[0, normalized_position].bytesize
        return !hfa_unicode_property_run_match_result(input, byte_position).nil?
      end
      return !hfa_unicode_property_match_result(input, normalized_position).nil? if !ascii_input && hfa_unicode_property_result_safe?

      return !hfa_repeated_class_backref_match_result(input, normalized_position).nil? if ascii_input && hfa_repeated_class_backref_result_safe?
      return !hfa_leading_literal_assertion_match_result(input, normalized_position).nil? if ascii_input && hfa_leading_literal_assertion_result_safe?
      return !hfa_scoped_casefold_backref_match_result(input, normalized_position).nil? if ascii_input && hfa_scoped_casefold_backref_spec
      return !hfa_variable_any_backref_match_result(input, normalized_position).nil? if ascii_input && hfa_variable_any_backref_spec

      if (literal = hfa_scoped_unicode_ignorecase_literal_value)
        result = hfa_unicode_ignorecase_literal_match_result(input, position, literal)
        return !result.nil? if timeout_unconfigured?

        return with_timeout { !result.nil? }
      end
      if hfa_unicode_ignorecase_literal_result_safe?
        normalized_position = normalize_match_position(input, position)
        result = hfa_unicode_ignorecase_literal_match_result(input, normalized_position)
        return !result.nil? if timeout_unconfigured?

        return with_timeout { !result.nil? }
      end
      if ascii_input && hfa_ignorecase_literal_result_safe?
        normalized_position = normalize_match_position(input, position)
        result = hfa_ignorecase_literal_match_result(input, normalized_position)
        return !result.nil? if timeout_unconfigured?

        return with_timeout { !result.nil? }
      end
      if ascii_input && ascii_repeated_literal_run_ast?
        result = hfa_repeated_literal_run_match_result(input, normalized_position)
        return !result.nil? if timeout_unconfigured?

        return with_timeout { !result.nil? }
      end

      hfa_generic_match?(input, position)
    end

    def match(input, position = 0)
      raise TypeError, "no implicit conversion of #{input.class} into String" unless input.is_a?(String)

      ascii_input = input.ascii_only?
      validate_encoding!(input, ascii_input: ascii_input)
      normalized_position = position.is_a?(Integer) && position.zero? ? 0 : normalize_match_position(input, position)

      if (class_source = hfa_unicode_class_direct_spec)
        byte_position = input.byteslice(0, normalized_position).bytesize
        result = hfa_unicode_class_direct_match_result(input, byte_position, class_source)
        return hfa_match_data(result, input) if result

        return nil
      end
      if (spec = hfa_casefold_class_direct_spec)
        byte_position = input.byteslice(0, normalized_position).bytesize
        result = hfa_casefold_class_direct_match_result(input, byte_position, spec)
        return hfa_match_data(result, input) if result

        return nil
      end
      if (spec = hfa_literal_capture_sequence_spec)
        byte_position = input.byteslice(0, normalized_position).bytesize
        result = hfa_literal_capture_sequence_match_result(input, byte_position, spec)
        return hfa_match_data(result, input) if result

        return nil
      end

      if (spec = hfa_bounded_sequence_direct_spec) && (ascii_input || spec[:table].nil?)
        result = hfa_bounded_sequence_direct_match_result(input, normalized_position)
        if result
          return hfa_match_data(result, input) if ascii_input

          match_start, match_finish, captures = result
          return MatchData.from_byte_offsets(input, match_start, match_finish, captures, hfa_result_names, self)
        end
        return nil
      end
      if ascii_input && (spec = hfa_fixed_literal_backref_spec)
        result = hfa_fixed_literal_backref_match_result(input, normalized_position, spec)
        return hfa_match_data(result, input) if result

        return nil
      end
      if ascii_input && (spec = hfa_alternation_literal_backref_spec)
        result = hfa_alternation_literal_backref_match_result(input, normalized_position, spec)
        return hfa_match_data(result, input) if result

        return nil
      end
      if ascii_input && (spec = hfa_repeated_literal_backref_spec)
        result = hfa_repeated_literal_backref_match_result(input, normalized_position, spec)
        return hfa_match_data(result, input) if result

        return nil
      end
      if ascii_input && (spec = hfa_literal_absence_suffix_spec)
        result = hfa_literal_absence_suffix_match_result(input, normalized_position, spec)
        return hfa_match_data(result, input) if result

        return nil
      end

      if ascii_input && hfa_capture_offset_strategy
        program = hfa_program
        if program
          result = program.match_result(input, normalized_position)
          return hfa_match_data(result, input) if result

          return nil
        end
      end

      return nil if hfa_always_fails?

      if hfa_empty_absence_result_safe?
        return hfa_match_data([input.bytesize, input.bytesize, []], input) if normalized_position <= input.bytesize

        return nil
      end
      if hfa_empty_nested_capture_spec
        result = hfa_empty_nested_capture_match_result(input, normalized_position)
        return hfa_match_data(result, input) if result

        return nil
      end
      if hfa_variable_subexpression_capture_spec
        result = hfa_variable_subexpression_capture_match_result(input, normalized_position)
        return hfa_match_data(result, input) if result

        return nil
      end
      if ascii_input && hfa_variable_capture_alternation_spec
        result = hfa_variable_capture_alternation_match_result(input, normalized_position)
        return hfa_match_data(result, input) if result

        return nil
      end
      if ascii_input && hfa_nested_literal_capture_alternation_spec
        result = hfa_nested_literal_capture_alternation_match_result(input, normalized_position)
        return hfa_match_data(result, input) if result

        return nil
      end
      if ascii_input && hfa_lookahead_alternation_backreference_spec
        result = hfa_lookahead_alternation_backreference_match_result(input, normalized_position)
        return hfa_match_data(result, input) if result

        return nil
      end
      if ascii_input && hfa_repeated_class_backref_result_safe?
        result = hfa_repeated_class_backref_match_result(input, normalized_position)
        return hfa_match_data(result, input) if result

        return nil
      end

      if hfa_positive_lookbehind_result_safe?
        result = hfa_positive_lookbehind_literal_match_result(input, normalized_position)
        return hfa_match_data(result, input) if result

        return nil
      end
      if hfa_negative_lookbehind_result_safe?
        result = hfa_negative_lookbehind_literal_match_result(input, normalized_position)
        return hfa_match_data(result, input) if result

        return nil
      end
      if hfa_class_lookbehind_parts
        result = hfa_class_lookbehind_match_result(input, normalized_position)
        return hfa_match_data(result, input) if result

        return nil
      end
      if ascii_input && hfa_adjacent_greedy_capture_result_safe?
        result = hfa_program.match_result(input, normalized_position)
        if result
          start, finish, = result
          first_finish = hfa_adjacent_greedy_capture_end(input, start, finish)
          return hfa_match_data([start, finish, [[start, first_finish], [first_finish, first_finish]]], input)
        end
        return nil
      end
      if !ascii_input && input.encoding == Encoding::UTF_8 && hfa_unicode_repeated_literal_capture_result_safe?
        result = hfa_unicode_repeated_literal_capture_match_result(input, position)
        return hfa_unicode_repeated_literal_capture_match_data(result, input) if result

        return nil
      end
      if !ascii_input && hfa_unicode_property_result_safe?
        result = hfa_unicode_property_match_result(input, normalized_position)
        return hfa_match_data(result, input) if result

        return nil
      end
      if !ascii_input && hfa_unicode_property_run_result_safe?
        result = hfa_unicode_property_run_match_result(input, normalized_position)
        return hfa_match_data(result, input) if result

        return nil
      end
      if hfa_literal_absence_result_safe?
        result = hfa_literal_absence_match_result(input, normalized_position, byte_mode: !ascii_input)
        return hfa_match_data(result, input) if result

        return nil
      end
      if ascii_input && hfa_match_reset_literal_result_safe?
        result = hfa_match_reset_literal_match_result(input, normalized_position)
        return hfa_match_data(result, input) if result

        return nil
      end
      if ascii_input && hfa_leading_literal_assertion_result_safe?
        result = hfa_leading_literal_assertion_match_result(input, normalized_position)
        return hfa_match_data(result, input) if result

        return nil
      end
      if ascii_input && hfa_atomic_literal_alternation_spec
        result = hfa_atomic_literal_alternation_match_result(input, normalized_position)
        return hfa_match_data(result, input) if result

        return nil
      end
      if ascii_input && hfa_scoped_casefold_backref_spec
        result = hfa_scoped_casefold_backref_match_result(input, normalized_position)
        return hfa_match_data(result, input) if result

        return nil
      end
      if ascii_input && hfa_variable_any_backref_spec
        result = hfa_variable_any_backref_match_result(input, normalized_position)
        return hfa_match_data(result, input) if result

        return nil
      end
      if ascii_input && hfa_lazy_literal_result_safe?
        result = hfa_lazy_literal_match_result(input, normalized_position)
        return hfa_match_data(result, input) if result

        return nil
      end
      if ascii_input && hfa_possessive_literal_string_result_safe?
        result = hfa_possessive_literal_string_match_result(input, normalized_position)
        return hfa_match_data(result, input) if result

        return nil
      end
      if (literal = hfa_scoped_unicode_ignorecase_literal_value)
        result = hfa_unicode_ignorecase_literal_match_result(input, position, literal)
        return hfa_match_data(result, input) if result

        return nil
      end
      if hfa_unicode_ignorecase_literal_result_safe?
        result = hfa_unicode_ignorecase_literal_match_result(input, position)
        return hfa_match_data(result, input) if result

        return nil
      end
      if ascii_input && hfa_ignorecase_literal_result_safe?
        result = hfa_ignorecase_literal_match_result(input, position)
        return hfa_match_data(result, input) if result

        return nil
      end
      if ascii_input && hfa_repeated_equal_length_literal_capture_result_safe?
        result = hfa_repeated_equal_length_literal_capture_match_result(input, normalized_position)
        return hfa_match_data(result, input) if result

        return nil
      end
      if ascii_input && hfa_literal_capture_before_alternation_result_safe?
        result = hfa_literal_capture_before_alternation_match_result(input, normalized_position)
        return hfa_match_data(result, input) if result

        return nil
      end
      if !ascii_input && hfa_unicode_repeated_literal_result_safe?
        result = hfa_unicode_repeated_literal_match_result(input, normalized_position)
        return hfa_match_data(result, input) if result

        return nil
      end
      return nil if ascii_input && hfa_unicode_repeated_literal_result_safe?

      if ascii_input && ascii_repeated_literal_run_ast?
        result = hfa_repeated_literal_run_match_result(input, normalized_position)
        return hfa_match_data(result, input) if result

        return nil
      end
      if ascii_input && hfa_class_run_positive_lookahead_result_safe?
        result = hfa_class_run_positive_lookahead_match_result(input, normalized_position)
        return hfa_match_data(result, input) if result

        return nil
      end
      if ascii_input && (spec = hfa_lookahead_literal_backreference_spec)
        result = hfa_lookahead_literal_backreference_match_result(input, normalized_position, spec)
        return hfa_match_data(result, input) if result

        return nil
      end
      hfa_generic_match(input, position, ascii_input: ascii_input)
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
      source = @source_pattern.dup
      return source if fixed_encoding? || !source.ascii_only?

      source.force_encoding(Encoding::US_ASCII)
    end

    def casefold?
      @options.include?("ignorecase")
    end

    def names
      capture_names.keys
    end

    def hfa_generic_match?(input, position = 0)
      program = hfa_program
      raise HybridAutomata::UnsupportedPattern, "pattern is outside the hybrid automaton" unless program

      hfa_timeout_budget_guard!(input)
      ascii_input = input.ascii_only?
      start = normalize_match_position(input, position)
      return false if start.negative?

      start = hfa_byte_position(input, start, ascii_input: ascii_input)
      with_timeout { program.match?(input, start) }
    end

    def hfa_generic_match(input, position = 0, ascii_input: nil)
      program = hfa_program
      raise HybridAutomata::UnsupportedPattern, "pattern is outside the hybrid automaton" unless program

      hfa_timeout_budget_guard!(input)
      ascii_input = input.ascii_only? if ascii_input.nil?
      start = normalize_match_position(input, position)
      return nil if start.negative?

      start = hfa_byte_position(input, start, ascii_input: ascii_input)
      result = with_timeout { program.match_result(input, start, include_nullable: true) }
      result ||= hfa_unicode_alternation_match_result(input, start)
      return nil unless result

      match_start, match_finish, captures = result
      if ascii_input || (captures.empty? && (hfa_exact_literal_result_safe? || hfa_unicode_exact_literal_result_safe? ||
                                             hfa_capture_count.positive?))
        hfa_match_data(result, input)
      else
        MatchData.from_byte_offsets(input, match_start, match_finish, captures, hfa_result_names, self)
      end
    end

    def hfa_timeout_budget_guard!(input)
      limit = @timeout.nil? ? self.class.timeout : @timeout
      return unless limit && input.bytesize > (limit * 100_000)
      return unless @source_pattern.include?("+") || @source_pattern.include?("*")

      raise TimeoutError, "regexp match timeout"
    end

    def hfa_unicode_alternation_match_result(input, position)
      return unless input.encoding == Encoding::UTF_8 && @ast.is_a?(AST::Alternation)

      branches = @ast.branches.map { |branch| branch.is_a?(AST::Sequence) && branch.parts.one? ? branch.parts.first : branch }
      return unless branches.all? { |branch| branch.is_a?(AST::Literal) || branch.is_a?(AST::CharacterClass) }

      byte_offset = 0
      input.each_char do |character|
        if byte_offset >= input.byteslice(0, position).bytesize
          branch = branches.find do |candidate|
            if candidate.is_a?(AST::Literal)
              input.byteslice(byte_offset, candidate.value.bytesize) == candidate.value
            else
              ClassPredicates.matches?(candidate.value, character)
            end
          end
          if branch
            length = branch.is_a?(AST::Literal) ? branch.value.bytesize : character.bytesize
            return [byte_offset, byte_offset + length, []]
          end
        end
        byte_offset += character.bytesize
      end
      nil
    end

    def hfa_generic_each_result(input, &block)
      return enum_for(__method__, input) unless block

      program = hfa_program
      raise HybridAutomata::UnsupportedPattern, "pattern is outside the hybrid automaton" unless program

      boundary_spec = hfa_scan_boundary_spec

      if boundary_spec
        position = 0
        while position <= input.bytesize
          result = program.match_result(input, position)
          break unless result

          if hfa_scan_boundary_match?(input, result[0], result[1], boundary_spec)
            captures = (hfa_top_level_capture_offsets(input, result[0], result[1]) if hfa_top_level_capture_plan) ||
                       hfa_generic_capture_offsets(input, result[0], result[1])
            block.call([result[0], result[1], captures || result[2]])
            position = [result[1], position + 1].max
          else
            position = [result[0] + 1, position + 1].max
          end
        end
        return true
      end

      program.each_match_result(input, 0) do |result|
        next unless hfa_scan_boundary_match?(input, result[0], result[1], boundary_spec)

        captures = (hfa_top_level_capture_offsets(input, result[0], result[1]) if hfa_top_level_capture_plan) ||
                   hfa_generic_capture_offsets(input, result[0], result[1])
        block.call([result[0], result[1], captures || result[2]])
      end
      true
    end

    # The position NFA omits capture tags. Reconstruct captures for
    # deterministic AST regions after the automaton identifies a match span.
    def hfa_generic_capture_offsets(input, start, finish)
      capture_count = hfa_capture_count
      return [] if capture_count.zero?

      if (whole_capture = hfa_whole_capture_offsets(start, finish))
        return whole_capture
      end

      return hfa_top_level_capture_offsets(input, start, finish) if hfa_top_level_capture_plan

      if (offsets = hfa_variable_backreference_capture_offsets(input, start, finish))
        return offsets
      end

      offsets = Array.new(capture_count)
      cursor = hfa_consume_capture_node(@ast, input, start, finish, offsets)
      cursor == finish ? offsets : nil
    end

    def hfa_top_level_capture_plan
      return @hfa_top_level_capture_plan if defined?(@hfa_top_level_capture_plan)

      parts = @ast.is_a?(AST::Sequence) ? @ast.parts : [@ast]
      captures = parts.select { |part| part.is_a?(AST::Group) && part.capture }
      @hfa_top_level_capture_plan = if captures.any? &&
                                       captures.all? { |group| hfa_capture_count(group.body).zero? } &&
                                       parts.all? { |part| hfa_top_level_capture_plan_node?(part) }
                                      parts.freeze
                                    else
                                      false
                                    end
    end

    def hfa_top_level_capture_plan_node?(node)
      return true if node.is_a?(AST::Literal) || hfa_zero_width_node?(node)
      return node.capture && hfa_capture_count(node.body).zero? if node.is_a?(AST::Group)

      return false unless hfa_capture_count(node).zero?
      return false unless node.is_a?(AST::Quantifier)

      node.expression.is_a?(AST::CharacterClass) || node.expression.is_a?(AST::Escape) ||
        node.expression.is_a?(AST::Literal)
    end

    def hfa_top_level_capture_offsets(input, start, finish)
      result = hfa_top_level_capture_match_result(input, start, finish)
      result && result[2]
    end

    def hfa_top_level_capture_match_result(input, start, finish, allow_short: false)
      offsets = Array.new(hfa_capture_count)
      cursor = start
      hfa_top_level_capture_plan.each_with_index do |part, index|
        if part.is_a?(AST::Literal)
          cursor += part.value.bytesize
          next
        end

        if part.is_a?(AST::Group) && part.capture
          group_start = cursor
          group_end = hfa_top_level_capture_group_end(part, input, cursor, finish,
                                                      hfa_top_level_capture_plan[index + 1], allow_short: allow_short)
          cursor = if group_end == :unsupported
                     hfa_consume_capture_node(part.body, input, cursor, finish, offsets)
                   else
                     group_end
                   end
          return unless cursor

          offsets[part.number - 1] = [group_start, cursor]
          next
        end

        cursor = hfa_consume_capture_node(part, input, cursor, finish, offsets)
        return unless cursor
      end
      return [start, cursor, offsets] if cursor == finish
      return [start, cursor, offsets] if allow_short && cursor < finish

      nil
    end

    def hfa_top_level_capture_group_end(group, input, cursor, finish, following, allow_short: false)
      return :unsupported unless input.ascii_only?

      body = group.body
      body = body.parts.first if body.is_a?(AST::Sequence) && body.parts.one?
      return :unsupported unless body.is_a?(AST::Quantifier) && body.mode == :greedy &&
                                 body.minimum.positive? && body.maximum.nil?

      table = hfa_capture_class_table(body.expression)
      return :unsupported unless table

      if following.nil? && allow_short
        position = cursor
        position += 1 while position < finish && table[input.getbyte(position)]
        return position
      end

      boundary = if following.is_a?(AST::Literal) && following.value.bytesize.positive?
                   if following.value.bytes.all? { |byte| !table[byte] }
                     input.index(following.value, cursor)
                   else
                     input.rindex(following.value, finish - following.value.bytesize)
                   end
                 elsif following.nil?
                   finish
                 end
      return :unsupported if boundary.nil?
      return nil if boundary <= cursor

      position = cursor
      position += 1 while position < boundary && table[input.getbyte(position)]
      position == boundary ? boundary : nil
    end

    def hfa_scan_boundary_spec
      return @hfa_scan_boundary_spec if defined?(@hfa_scan_boundary_spec)

      parts = @ast.is_a?(AST::Sequence) ? @ast.parts : []
      first = parts.first
      last = parts.last
      @hfa_scan_boundary_spec = if first.is_a?(AST::Escape) && last.is_a?(AST::Escape) &&
                                   %i[word_boundary nonword_boundary].include?(first.kind) &&
                                   first.kind == last.kind
                                  first.kind
                                else
                                  false
                                end
    end

    def hfa_capture_literal_prefixes(node)
      case node
      when AST::Literal
        [node.value]
      when AST::Group, AST::OptionGroup, AST::AtomicGroup
        hfa_capture_literal_prefixes(node.body)
      when AST::Alternation
        node.branches.flat_map { |branch| hfa_capture_literal_prefixes(branch) }
      when AST::Sequence
        literal_prefix = +""
        node.parts.each do |part|
          if part.is_a?(AST::Literal)
            literal_prefix << part.value
            next
          end
          return [literal_prefix] unless literal_prefix.empty?
          return [] unless hfa_zero_width_node?(part)
        end
        literal_prefix.empty? ? [] : [literal_prefix]
      else
        []
      end
    end

    def hfa_whole_capture_offsets(start, finish)
      group = hfa_whole_capture_group(@ast)
      return unless group

      offsets = Array.new(hfa_capture_count)
      offsets[group.number - 1] = [start, finish]
      offsets
    end

    def hfa_whole_capture_group(node = nil)
      return @hfa_whole_capture_group if node.nil? && defined?(@hfa_whole_capture_group)
      return @hfa_whole_capture_group = hfa_find_whole_capture_group(@ast) if node.nil?

      hfa_find_whole_capture_group(node)
    end

    def hfa_find_whole_capture_group(node)
      case node
      when AST::Group
        return node if node.capture && hfa_capture_count(node.body).zero?
      when AST::Sequence
        candidates = node.parts.filter_map { |part| hfa_find_whole_capture_group(part) }
        return candidates.first if candidates.one? &&
                                   node.parts.all? { |part| part.equal?(candidates.first) || hfa_zero_width_node?(part) }
      when AST::OptionGroup, AST::AtomicGroup
        return hfa_find_whole_capture_group(node.body)
      end
      nil
    end

    def hfa_zero_width_node?(node)
      node.is_a?(AST::Assertion) || node.is_a?(AST::Anchor) ||
        (node.is_a?(AST::Escape) && %i[word_boundary nonword_boundary].include?(node.kind))
    end

    def hfa_variable_backreference_capture_offsets(input, start, finish)
      return unless @ast.is_a?(AST::Sequence) && @ast.parts.length == 2

      group, reference = @ast.parts
      return unless group.is_a?(AST::Group) && group.capture && reference.is_a?(AST::Backreference)
      return unless reference.identifier.to_i == group.number || reference.identifier.to_s == group.name.to_s

      length = finish - start
      return unless length.even?

      midpoint = start + (length / 2)
      return unless input.byteslice(start, midpoint - start) == input.byteslice(midpoint, midpoint - start)

      offsets = Array.new(hfa_capture_count)
      offsets[group.number - 1] = [start, midpoint]
      offsets
    end

    def hfa_capture_count(node = nil)
      return @hfa_capture_count if node.nil? && defined?(@hfa_capture_count)
      return @hfa_capture_count = hfa_capture_count(@ast) if node.nil?

      case node
      when AST::Group
        [node.number || 0, hfa_capture_count(node.body)].max
      when AST::Sequence
        node.parts.map { |part| hfa_capture_count(part) }.max || 0
      when AST::Alternation
        node.branches.map { |branch| hfa_capture_count(branch) }.max || 0
      when AST::Quantifier
        hfa_capture_count(node.expression)
      when AST::OptionGroup, AST::AtomicGroup
        hfa_capture_count(node.body)
      else
        0
      end
    end

    def hfa_consume_capture_node(node, input, cursor, finish, offsets, ascii_input = nil)
      ascii_input = input.ascii_only? if ascii_input.nil?

      case node
      when AST::Literal
        value = node.value
        input.byteslice(cursor, value.bytesize) == value ? cursor + value.bytesize : nil
      when AST::CharacterClass
        character = input[cursor]
        character && ClassPredicates.compiled(node.value).matches?(character) ? cursor + character.bytesize : nil
      when AST::Escape
        return cursor if %i[word_boundary nonword_boundary].include?(node.kind)

        character = input[cursor]
        character && CharacterPredicates.escape_matches?(node.kind, character) ? cursor + character.bytesize : nil
      when AST::Property
        character = input[cursor]
        matched = character && UnicodeProperties.matches?(node.name, character)
        character && (matched ^ node.negated) ? cursor + character.bytesize : nil
      when AST::Any
        character = input[cursor]
        character ? cursor + character.bytesize : nil
      when AST::Assertion, AST::Anchor
        cursor
      when AST::Group
        group_start = cursor
        result = hfa_consume_capture_node(node.body, input, cursor, finish, offsets, ascii_input)
        offsets[node.number - 1] = [group_start, result] if result && node.capture
        result
      when AST::OptionGroup, AST::AtomicGroup
        hfa_consume_capture_node(node.body, input, cursor, finish, offsets, ascii_input)
      when AST::Sequence
        node.parts.reduce(cursor) do |position, part|
          position && hfa_consume_capture_node(part, input, position, finish, offsets, ascii_input)
        end
      when AST::Alternation
        node.branches.each do |branch|
          snapshot = offsets.dup
          result = hfa_consume_capture_node(branch, input, cursor, finish, offsets, ascii_input)
          return result if result

          offsets.replace(snapshot)
        end
        nil
      when AST::Quantifier
        return hfa_consume_ascii_class_quantifier(node, input, cursor, finish) if ascii_input && node.expression.is_a?(AST::CharacterClass)

        count = 0
        position = cursor
        while node.maximum.nil? || count < node.maximum
          result = hfa_consume_capture_node(node.expression, input, position, finish, offsets, ascii_input)
          break unless result && result > position && result <= finish

          position = result
          count += 1
        end
        count >= node.minimum ? position : nil
      end
    end

    def hfa_consume_ascii_class_quantifier(node, input, cursor, finish)
      if node.maximum.nil?
        delimiter = case node.expression.value
                    when "^\\]" then "]"
                    when "^ " then " "
                    end
        if delimiter
          boundary = input.index(delimiter, cursor)
          return boundary if boundary && boundary <= finish

          return finish
        end
      end

      predicate = ClassPredicates.compiled(node.expression.value)
      table = predicate.ascii_table
      count = 0
      limit = node.maximum || finish - cursor
      while count < limit && cursor < finish && table[input.getbyte(cursor)]
        cursor += 1
        count += 1
      end
      count >= node.minimum ? cursor : nil
    end

    def named_captures
      CaptureNameCollector.indices(@ast)
    end

    private

    def capture_names
      @capture_names ||= CaptureNameCollector.call(@ast)
    end

    def normalize_match_position(input, position)
      position = position.to_int if position.respond_to?(:to_int)
      raise TypeError, "no implicit conversion of #{position.class} into Integer" unless position.is_a?(Integer)

      position += input.length if position.negative?
      position
    end

    def hfa_byte_position(input, position, ascii_input: nil)
      ascii_input = input.ascii_only? if ascii_input.nil?
      return position if ascii_input || position.negative?
      return input.bytesize + 1 if position > input.length

      input[0, position].bytesize
    end

    def timeout_unconfigured?
      @timeout.nil? && self.class.timeout.nil?
    end

    def hfa_program
      return @hfa_program if defined?(@hfa_program)

      @hfa_program = HybridAutomata.compile_ast(@ast, options: @options)
    rescue HybridAutomata::UnsupportedPattern
      @hfa_program = false
    end

    def hfa_compilation_program
      return @hfa_compilation_program if defined?(@hfa_compilation_program)

      @hfa_compilation_program_mutex.synchronize do
        return @hfa_compilation_program if defined?(@hfa_compilation_program)

        unit = HybridAutomata::Optimization::Pipeline.new([]).call(
          @ast, options: @options, encoding: encoding
        )
        @hfa_compilation_program = HybridAutomata::Optimization::CompilationProgram.new(
          unit.component_graph, unit.head_dfa(row_budget: 4_096)
        ).freeze
      end
    end

    def hfa_always_fails?
      return true if @ast.is_a?(AST::Sequence) && @ast.parts.one? &&
                     @ast.parts.first.is_a?(AST::Assertion) && @ast.parts.first.kind == :negative &&
                     @ast.parts.first.body.is_a?(AST::Sequence) && @ast.parts.first.body.parts.empty?

      return false unless @ast.is_a?(AST::Sequence)

      anchor_index = @ast.parts.index do |part|
        part.is_a?(AST::Anchor) && part.kind == :anchor_absolute_start
      end
      return true if anchor_index && @ast.parts[0...anchor_index].any? { |part| hfa_definitely_nonempty?(part) }

      end_anchor_index = @ast.parts.index do |part|
        part.is_a?(AST::Anchor) && part.kind == :anchor_absolute_end
      end
      end_anchor_index && @ast.parts[(end_anchor_index + 1)..].any? { |part| hfa_definitely_nonempty?(part) }
    end

    def hfa_definitely_nonempty?(node)
      case node
      when AST::Literal
        node.value.bytesize.positive?
      when AST::CharacterClass, AST::Any
        true
      when AST::Group
        hfa_definitely_nonempty?(node.body)
      when AST::Sequence
        node.parts.any? { |part| hfa_definitely_nonempty?(part) }
      when AST::Quantifier
        node.minimum.to_i.positive? && hfa_definitely_nonempty?(node.expression)
      else
        false
      end
    end

    def hfa_unicode_class_direct_spec
      return @hfa_unicode_class_direct_spec if defined?(@hfa_unicode_class_direct_spec)
      return @hfa_unicode_class_direct_spec = false if casefold?

      parts = @ast.is_a?(AST::Sequence) ? @ast.parts : []
      node = parts.one? && parts.first
      source = node.value if node.is_a?(AST::CharacterClass)
      direct = source if source && (!source.ascii_only? || source.include?("\\p") || source.include?("\\P") ||
                                   source.include?("\\u") || source.include?("\\M-") || source.include?("[:"))
      @hfa_unicode_class_direct_spec = direct
    end

    def hfa_unicode_class_direct_match_result(input, byte_position, source)
      offset = 0
      input.each_char do |character|
        return [offset, offset + character.bytesize, []] if offset >= byte_position && ClassPredicates.matches?(source, character)

        offset += character.bytesize
      end
      nil
    end

    def hfa_casefold_class_direct_spec
      return @hfa_casefold_class_direct_spec if defined?(@hfa_casefold_class_direct_spec)
      return @hfa_casefold_class_direct_spec = false unless casefold?

      parts = @ast.is_a?(AST::Sequence) ? @ast.parts : []
      node = parts.one? && parts.first
      source = node.value if node.is_a?(AST::CharacterClass)
      metadata = source && ClassPredicates.compiled(source, ignorecase: true).metadata
      literals = metadata&.literals
      @hfa_casefold_class_direct_spec = if literals&.any? && metadata.ignorecase_expansion != :none
                                          [literals.freeze, metadata.ignorecase_expansion == :full_fold ? 2 : 1].freeze
                                        else
                                          false
                                        end
    end

    def hfa_casefold_class_direct_match_result(input, byte_position, spec)
      literals, maximum_chars = spec
      characters = input.each_char.to_a
      offsets = Array.new(characters.length + 1, 0)
      characters.each_with_index { |character, index| offsets[index + 1] = offsets[index] + character.bytesize }
      start_index = offsets.index { |offset| offset >= byte_position } || characters.length
      start_index.upto(characters.length - 1) do |index|
        maximum_chars.downto(1) do |length|
          candidate = characters[index, length]&.join
          next unless candidate && literals.any? { |literal| literal.casecmp?(candidate) }

          return [offsets[index], offsets[index + length], []]
        end
      end
      nil
    end

    def hfa_literal_capture_sequence_spec
      return @hfa_literal_capture_sequence_spec if defined?(@hfa_literal_capture_sequence_spec)
      return @hfa_literal_capture_sequence_spec = false if casefold?
      return @hfa_literal_capture_sequence_spec = false if CaptureNameCollector.indices(@ast).values.any? { |indices| indices.length > 1 }

      parts = @ast.is_a?(AST::Sequence) ? @ast.parts : []
      tokens = []
      capture_count = 0
      valid = parts.length > 1 && parts.all? do |part|
        case part
        when AST::Literal
          tokens << { kind: :fixed, value: part.value, captures: [] }.freeze
          part.value.ascii_only? || !part.value.empty?
        when AST::Group
          repeated = if part.capture && part.body.is_a?(AST::Sequence) && part.body.parts.one?
                       quantifier = part.body.parts.first
                       quantifier if quantifier.is_a?(AST::Quantifier) && quantifier.kind == :+ &&
                                     quantifier.mode == :greedy && quantifier.expression.is_a?(AST::Literal)
                     end
          if repeated
            value = repeated.expression.value
            next false unless value.ascii_only? && value.bytesize.positive?

            capture_count = [capture_count, part.number].max
            tokens << { kind: :repeat, value: value, number: part.number, capture_full: true }.freeze
            next true
          end
          info = hfa_literal_capture_group_info(part)
          next false unless info

          capture_count = [capture_count, *info[:captures].map(&:first)].max
          tokens << { kind: :fixed, value: info[:value], captures: info[:captures] }.freeze
          true
        when AST::Quantifier
          group = part.expression
          info = group.is_a?(AST::Group) && group.capture ? hfa_literal_capture_group_info(group) : nil
          next false unless info && info[:captures].length == 1 && %i[+ ?].include?(part.kind) &&
                            part.mode == :greedy

          capture_count = [capture_count, group.number].max
          kind = part.kind == :+ ? :repeat : :optional
          tokens << { kind: kind, value: info[:value], number: group.number }.freeze
          true
        else
          false
        end
      end
      valid &&= %i[fixed repeat].include?(tokens.first&.fetch(:kind)) && tokens.first[:value].bytesize.positive?
      @hfa_literal_capture_sequence_spec = if valid && tokens.any? { |token| %i[repeat optional].include?(token[:kind]) }
                                             [tokens.freeze, capture_count].freeze
                                           else
                                             false
                                           end
    end

    def hfa_literal_capture_group_info(group)
      value, captures = hfa_literal_capture_body_info(group.body)
      return unless value && group.number

      [{ value: value, captures: [[group.number, 0, value.bytesize], *captures] }].first
    end

    def hfa_literal_capture_body_info(body)
      nodes = body.is_a?(AST::Sequence) ? body.parts : [body]
      value = +""
      captures = []
      nodes.each do |node|
        case node
        when AST::Literal
          return unless node.value.bytesize.positive?

          value << node.value
        when AST::Group
          return unless node.capture

          nested = hfa_literal_capture_group_info(node)
          return unless nested

          start = value.bytesize
          value << nested[:value]
          nested[:captures].each { |number, from, to| captures << [number, from + start, to + start] }
        else
          return
        end
      end
      [value.freeze, captures.freeze]
    end

    def hfa_literal_capture_sequence_match_result(input, byte_position, spec)
      tokens, capture_count = spec
      first = tokens.first[:value]
      candidate = input.b.index(first.b, byte_position)
      while candidate
        cursor = candidate
        captures = Array.new(capture_count)
        valid = true
        tokens.each do |token|
          case token[:kind]
          when :fixed
            value = token[:value]
            unless input.byteslice(cursor, value.bytesize) == value
              valid = false
              break
            end
            token[:captures].each do |number, from, to|
              captures[number - 1] = [cursor + from, cursor + to]
            end
            cursor += value.bytesize
          when :repeat
            start = cursor
            value = token[:value]
            cursor += value.bytesize while input.byteslice(cursor, value.bytesize) == value
            if cursor == start
              valid = false
              break
            end
            capture_start = token[:capture_full] ? start : cursor - value.bytesize
            captures[token[:number] - 1] = [capture_start, cursor]
          when :optional
            value = token[:value]
            if input.byteslice(cursor, value.bytesize) == value
              captures[token[:number] - 1] = [cursor, cursor + value.bytesize]
              cursor += value.bytesize
            end
          end
        end
        return [candidate, cursor, captures] if valid

        candidate = input.b.index(first.b, candidate + 1)
      end
      nil
    end

    def hfa_literal_absence_result_safe?
      return @hfa_literal_absence_safe if defined?(@hfa_literal_absence_safe)

      body = hfa_literal_absence_body
      literal = hfa_literal_absence_body_literal(body)
      @hfa_literal_absence_safe = literal&.ascii_only? && literal.bytesize.positive? &&
                                  !casefold? && hfa_program
    end

    def hfa_literal_absence_parts
      @ast.is_a?(AST::Sequence) ? @ast.parts : []
    end

    def hfa_literal_absence_body
      parts = hfa_literal_absence_parts
      parts.first.body if parts.one? && parts.first.is_a?(AST::Absence)
    end

    def hfa_literal_absence_body_literal(body)
      body = body.parts.first if body.is_a?(AST::Sequence) && body.parts.one?
      body = body.body if body.is_a?(AST::Group) && body.capture
      literal_ast_value(body)
    end

    def hfa_literal_absence_suffix_spec
      return @hfa_literal_absence_suffix_spec if defined?(@hfa_literal_absence_suffix_spec)
      return @hfa_literal_absence_suffix_spec = false if casefold?

      parts = hfa_literal_absence_parts
      absence, suffix = parts
      body = absence.body if absence.is_a?(AST::Absence)
      forbidden = hfa_literal_absence_body_literal(body)
      valid = parts.length == 2 && forbidden&.ascii_only? && forbidden.bytesize.positive? &&
              suffix.is_a?(AST::Literal) && suffix.value.ascii_only? && suffix.value.bytesize.positive?
      @hfa_literal_absence_suffix_spec = valid ? [forbidden.freeze, suffix.value.freeze].freeze : false
    end

    def hfa_literal_absence_suffix_match_result(input, position, spec)
      forbidden, suffix = spec
      suffix_position = input.index(suffix, position)
      while suffix_position
        forbidden_position = input.rindex(forbidden, suffix_position - 1)
        start = [position, forbidden_position ? forbidden_position + 1 : position].max
        return [start, suffix_position + suffix.bytesize, []] if start <= suffix_position

        suffix_position = input.index(suffix, suffix_position + 1)
      end
      nil
    end

    def hfa_empty_absence_result_safe?
      return @hfa_empty_absence_safe if defined?(@hfa_empty_absence_safe)

      body = hfa_literal_absence_body
      @hfa_empty_absence_safe = body.is_a?(AST::Sequence) && body.parts.empty?
    end

    def hfa_literal_absence_value
      hfa_literal_absence_result_safe? && hfa_literal_absence_body_literal(hfa_literal_absence_body)
    end

    def hfa_literal_absence_capture_spec
      body = hfa_literal_absence_body
      body = body.parts.first if body.is_a?(AST::Sequence) && body.parts.one?
      return unless body.is_a?(AST::Group) && body.capture

      literal = literal_ast_value(body.body)
      literal && [body.number, literal].freeze
    end

    def hfa_literal_absence_match_result(input, position, byte_mode: false)
      literal = hfa_literal_absence_value
      capture_spec = hfa_literal_absence_capture_spec
      search_input = byte_mode ? input.b : input
      search_literal = byte_mode ? literal.b : literal
      search_position = 0
      while (occurrence = search_input.index(search_literal, search_position))
        candidate = occurrence + literal.bytesize
        if candidate > position
          finish = occurrence >= position ? candidate - 1 : candidate
          captures = if capture_spec
                       offsets = Array.new(capture_spec[0])
                       offsets[capture_spec[0] - 1] = [occurrence, candidate]
                       offsets
                     else
                       []
                     end
          return [position, finish, captures]
        end
        search_position = occurrence + 1
      end
      captures = capture_spec ? Array.new(capture_spec[0]) : []
      [position, input.bytesize, captures]
    end

    def hfa_scoped_unicode_ignorecase_literal_value
      return @hfa_scoped_unicode_ignorecase_literal if defined?(@hfa_scoped_unicode_ignorecase_literal)

      parts = @ast.is_a?(AST::Sequence) ? @ast.parts : []
      group = parts.one? && parts.first
      body = group.body if group.is_a?(AST::OptionGroup) && group.ignorecase &&
                           group.multiline.nil? && group.extended.nil?
      literal = literal_ast_value(body) if body
      @hfa_scoped_unicode_ignorecase_literal = literal if literal&.bytesize&.positive? && !literal.ascii_only?
    end

    def hfa_unicode_property_result_safe?
      return @hfa_unicode_property_safe if defined?(@hfa_unicode_property_safe)

      parts = @ast.is_a?(AST::Sequence) ? @ast.parts : []
      node = parts.first
      @hfa_unicode_property_safe = parts.one? && node.is_a?(AST::Property) &&
                                   !casefold? &&
                                   !hfa_unicode_property_spec.nil?
    end

    def hfa_unicode_property_spec
      return @hfa_unicode_property_spec if defined?(@hfa_unicode_property_spec)

      node = @ast.parts.first
      normalized = node.name.sub("Is", "").sub("^", "")
      matcher = UnicodeProperties::PROPERTY_MATCHERS[normalized]
      @hfa_unicode_property_spec = matcher && [UnicodeProperties.method(matcher), node.negated].freeze
    end

    def hfa_unicode_property_match_result(input, position)
      predicate, negated = hfa_unicode_property_spec
      cursor = 0
      hfa_unicode_property_codepoint_events(input) do |codepoint, bytesize|
        return [cursor, cursor + bytesize, []] if cursor >= position && (hfa_unicode_property_codepoint_match?(codepoint, predicate) ^ negated)

        cursor += bytesize
      end
      nil
    end

    def hfa_unicode_property_codepoint_events(input)
      return enum_for(__method__, input) unless block_given?

      if input.encoding == Encoding::UTF_8
        input.each_codepoint { |codepoint| yield codepoint, utf8_codepoint_bytesize(codepoint) }
      else
        input.each_char do |character|
          yield character.encode(Encoding::UTF_8).ord, character.bytesize
        end
      end
    end

    def hfa_unicode_property_codepoint_match?(codepoint, predicate)
      return hfa_unicode_letter_codepoint?(codepoint) if predicate == UnicodeProperties.method(:letter?)

      predicate.call(codepoint.chr(Encoding::UTF_8))
    end

    def hfa_ignorecase_literal_result_safe?
      return @hfa_ignorecase_literal_safe if defined?(@hfa_ignorecase_literal_safe)

      literal = literal_ast_value(@ast)
      @hfa_ignorecase_literal_safe = if casefold? && literal&.ascii_only? &&
                                        literal.bytesize.positive?
                                       hfa_program
                                     else
                                       false
                                     end
    end

    def hfa_exact_literal_result_safe?
      return @hfa_exact_literal_safe if defined?(@hfa_exact_literal_safe)

      literal = hfa_exact_literal_value
      @hfa_exact_literal_safe = literal&.bytesize&.positive? && literal.ascii_only? &&
                                !casefold?
    end

    def hfa_unicode_exact_literal_result_safe?
      return @hfa_unicode_exact_literal_safe if defined?(@hfa_unicode_exact_literal_safe)

      literal = hfa_exact_literal_value
      @hfa_unicode_exact_literal_safe = literal&.bytesize&.positive? &&
                                        literal.each_codepoint.any? { |codepoint| codepoint > 0xFF } &&
                                        !casefold?
    end

    def hfa_exact_literal_value
      return @hfa_exact_literal_value if defined?(@hfa_exact_literal_value)

      @hfa_exact_literal_value = (literal_ast_value(@ast) if @ast.is_a?(AST::Literal) || @ast.is_a?(AST::Sequence))
    end

    def hfa_leading_literal_assertion_result_safe?
      return @hfa_leading_literal_assertion_safe if defined?(@hfa_leading_literal_assertion_safe)

      parts = @ast.is_a?(AST::Sequence) ? @ast.parts : []
      index = 0
      guards = []
      while (assertion = parts[index]).is_a?(AST::Assertion) && %i[positive negative].include?(assertion.kind)
        guard = literal_ast_value(assertion.body)
        break unless guard

        guards << [assertion.kind, guard]
        index += 1
      end
      body = parts[index..]
      literal = body&.all? { |part| part.is_a?(AST::Literal) } ? body.map(&:value).join : nil
      @hfa_leading_literal_assertion_safe = [literal, guards] if literal&.bytesize&.positive? && guards.any?
      values = @hfa_leading_literal_assertion_safe
      @hfa_leading_literal_assertion_safe = false unless values && values[0].ascii_only? &&
                                                         values[1].all? { |_, guard| guard.ascii_only? && guard.bytesize.positive? }
      @hfa_leading_literal_assertion_safe
    end

    def hfa_leading_literal_assertion_match_result(input, position,
                                                   assertion = hfa_leading_literal_assertion_result_safe?)
      literal, guards = assertion
      candidate = input.index(literal, position)
      while candidate
        matches = guards.all? do |kind, guard|
          if kind == :positive
            input.byteslice(candidate, guard.bytesize) == guard
          else
            input.byteslice(candidate, guard.bytesize) != guard
          end
        end
        return [candidate, candidate + literal.bytesize, []] if matches

        candidate = input.index(literal, candidate + 1)
      end
      nil
    end

    def hfa_atomic_literal_alternation_spec
      return @hfa_atomic_literal_alternation_spec if defined?(@hfa_atomic_literal_alternation_spec)

      parts = @ast.is_a?(AST::Sequence) ? @ast.parts : []
      group, suffix = parts
      branches = group.body.branches if group.is_a?(AST::AtomicGroup) &&
                                        group.body.is_a?(AST::Alternation) && suffix.is_a?(AST::Literal)
      values = branches&.map { |branch| literal_ast_value(branch) }
      @hfa_atomic_literal_alternation_spec = if parts.length == 2 && values&.all? do |value|
        value&.ascii_only? && value.bytesize.positive?
      end
                                               suffix.value.ascii_only? && suffix.value.bytesize.positive?
                                               [values.freeze, suffix.value].freeze
                                             else
                                               false
                                             end
    end

    def hfa_atomic_literal_alternation_match_result(input, position)
      branches, suffix = hfa_atomic_literal_alternation_spec
      candidate = branches.filter_map { |value| input.index(value, position) }.min
      while candidate
        branch = branches.find { |value| input.byteslice(candidate, value.bytesize) == value }
        if branch
          finish = candidate + branch.bytesize + suffix.bytesize
          return [candidate, finish, []] if input.byteslice(candidate + branch.bytesize, suffix.bytesize) == suffix
        end
        candidate = branches.filter_map { |value| input.index(value, candidate + 1) }.min
      end
      nil
    end

    def hfa_atomic_literal_alternation_each_result(input, &block)
      branches, suffix = hfa_atomic_literal_alternation_spec
      position = 0
      loop do
        candidate = branches.filter_map { |value| input.index(value, position) }.min
        break unless candidate

        branch = branches.find { |value| input.byteslice(candidate, value.bytesize) == value }
        if branch
          finish = candidate + branch.bytesize + suffix.bytesize
          if input.byteslice(candidate + branch.bytesize, suffix.bytesize) == suffix
            block.call([candidate, finish, []])
            position = finish
            next
          end
        end
        position = candidate + 1
      end
    end

    def hfa_scoped_casefold_backref_spec
      return @hfa_scoped_casefold_backref_spec if defined?(@hfa_scoped_casefold_backref_spec)

      parts = @ast.is_a?(AST::Sequence) ? @ast.parts : []
      group, option_group = parts
      literal = group.body if group.is_a?(AST::Group) && group.capture
      literal = literal_ast_value(literal)
      reference = option_group.body if option_group.is_a?(AST::OptionGroup) && option_group.ignorecase == true &&
                                       option_group.multiline.nil? && option_group.extended.nil?
      reference = reference.parts.first if reference.is_a?(AST::Sequence) && reference.parts.one?
      valid = parts.length == 2 && literal&.ascii_only? && literal.bytesize.positive? &&
              reference.is_a?(AST::Backreference) &&
              (reference.identifier.to_s == group.name.to_s || reference.identifier.to_i == group.number)
      @hfa_scoped_casefold_backref_spec = valid ? [literal, group.number].freeze : false
    end

    def hfa_scoped_casefold_backref_match_result(input, position)
      literal, number = hfa_scoped_casefold_backref_spec
      candidate = input.index(literal, position)
      while candidate
        repeated = candidate + literal.bytesize
        if input.byteslice(repeated, literal.bytesize)&.casecmp?(literal)
          captures = Array.new(number)
          captures[number - 1] = [candidate, repeated]
          return [candidate, repeated + literal.bytesize, captures]
        end
        candidate = input.index(literal, candidate + 1)
      end
      nil
    end

    def hfa_variable_any_backref_spec
      return @hfa_variable_any_backref_spec if defined?(@hfa_variable_any_backref_spec)

      parts = @ast.is_a?(AST::Sequence) ? @ast.parts : []
      group, reference = parts
      body = group.body if group.is_a?(AST::Group) && group.capture
      body = body.parts.first if body.is_a?(AST::Sequence) && body.parts.one?
      valid = parts.length == 2 && group.is_a?(AST::Group) && group.capture &&
              body.is_a?(AST::Quantifier) && body.kind == :* && body.mode == :greedy &&
              body.expression.is_a?(AST::Any) && reference.is_a?(AST::Backreference) &&
              (reference.identifier.to_s == group.name.to_s || reference.identifier.to_i == group.number)
      @hfa_variable_any_backref_spec = valid ? group.number : false
    end

    def hfa_fixed_literal_backref_spec
      return @hfa_fixed_literal_backref_spec if defined?(@hfa_fixed_literal_backref_spec)
      return @hfa_fixed_literal_backref_spec = false if casefold?

      parts = @ast.is_a?(AST::Sequence) ? @ast.parts : []
      groups = {}
      names = {}
      captures = {}
      literal = +""
      reference_seen = false
      valid = parts.all? do |part|
        case part
        when AST::Literal
          literal << part.value
          part.value.ascii_only?
        when AST::Group
          value = literal_ast_value(part.body)
          next false unless part.capture && value&.ascii_only? && value.bytesize.positive?

          start = literal.bytesize
          literal << value
          finish = literal.bytesize
          groups[part.number] = value
          names[part.name.to_s] = part.number if part.name
          captures[part.number] = [start, finish]
          true
        when AST::Backreference
          number = if part.named
                     names[part.identifier.to_s]
                   else
                     part.identifier.to_i
                   end
          value = groups[number]
          next false unless value

          literal << value
          reference_seen = true
          true
        else
          false
        end
      end
      @hfa_fixed_literal_backref_spec = if valid && reference_seen && literal.bytesize.positive?
                                          [literal.freeze, captures.freeze, groups.keys.max].freeze
                                        else
                                          false
                                        end
    end

    def hfa_alternation_literal_backref_spec
      return @hfa_alternation_literal_backref_spec if defined?(@hfa_alternation_literal_backref_spec)

      parts = @ast.is_a?(AST::Sequence) ? @ast.parts : []
      group, backref = parts
      branches = if group.is_a?(AST::Group) && group.capture && group.body.is_a?(AST::Alternation)
                   group.body.branches.map { |branch| literal_ast_value(branch) }
                 end
      valid = parts.length == 2 && branches&.all? { |value| value&.ascii_only? && value.bytesize.positive? } &&
              backref.is_a?(AST::Backreference) &&
              (backref.identifier.to_i == group.number || backref.identifier.to_s == group.name.to_s)
      @hfa_alternation_literal_backref_spec = valid ? [branches.freeze, group.number].freeze : false
    end

    def hfa_alternation_literal_backref_match_result(input, position, spec)
      branches, number = spec
      cursor = position
      while cursor <= input.bytesize
        branch = branches.find { |value| input.byteslice(cursor, value.bytesize * 2) == value * 2 }
        if branch
          finish = cursor + branch.bytesize * 2
          captures = Array.new(number)
          captures[number - 1] = [cursor, cursor + branch.bytesize]
          return [cursor, finish, captures]
        end
        cursor += 1
      end
      nil
    end

    def hfa_fixed_literal_backref_match_result(input, position, spec)
      literal, capture_offsets, capture_count = spec
      start = input.index(literal, position)
      return unless start

      captures = Array.new(capture_count)
      capture_offsets.each do |number, (offset_start, offset_finish)|
        captures[number - 1] = [start + offset_start, start + offset_finish]
      end
      [start, start + literal.bytesize, captures]
    end

    def hfa_repeated_literal_backref_spec
      return @hfa_repeated_literal_backref_spec if defined?(@hfa_repeated_literal_backref_spec)
      return @hfa_repeated_literal_backref_spec = false if casefold?

      parts = @ast.is_a?(AST::Sequence) ? @ast.parts : []
      repeat, separator, reference = parts
      group = repeat.expression if repeat.is_a?(AST::Quantifier)
      body = group.body if group.is_a?(AST::Group) && group.capture
      body = body.parts.first if body.is_a?(AST::Sequence) && body.parts.one?
      valid = repeat.is_a?(AST::Quantifier) && repeat.kind == :+ && repeat.mode == :greedy &&
              body.is_a?(AST::Literal) && body.value.ascii_only? &&
              separator.is_a?(AST::Literal) && separator.value.ascii_only? && separator.value.bytesize.positive? &&
              reference.is_a?(AST::Backreference) &&
              (reference.identifier.to_i == group.number || reference.identifier.to_s == group.name.to_s)
      @hfa_repeated_literal_backref_spec = if valid
                                             [body.value.freeze, separator.value.freeze, group.number].freeze
                                           else
                                             false
                                           end
    end

    def hfa_repeated_literal_backref_match_result(input, position, spec)
      unit, separator, number = spec
      unit_size = unit.bytesize
      separator_position = input.index(separator, position)
      while separator_position
        run_start = separator_position
        run_start -= unit_size while run_start >= unit_size &&
                                     input.byteslice(run_start - unit_size, unit_size) == unit
        next_start = separator_position + separator.bytesize
        if run_start < separator_position && input.byteslice(next_start, unit_size) == unit
          captures = Array.new(number)
          captures[number - 1] = [separator_position - unit_size, separator_position]
          return [run_start, next_start + unit_size, captures]
        end
        separator_position = input.index(separator, separator_position + separator.bytesize)
      end
      nil
    end

    def hfa_variable_any_backref_match_result(input, position)
      number = hfa_variable_any_backref_spec
      run_end = input.index("\n", position) || input.bytesize
      run_length = run_end - position
      length = run_length / 2
      while length.positive?
        repeated = position + length
        if input.byteslice(position, length) == input.byteslice(repeated, length)
          captures = Array.new(number)
          captures[number - 1] = [position, repeated]
          return [position, repeated + length, captures]
        end
        length -= 1
      end
      captures = Array.new(number)
      captures[number - 1] = [position, position]
      [position, position, captures]
    end

    def hfa_possessive_literal_string_result_safe?
      return @hfa_possessive_literal_string_safe if defined?(@hfa_possessive_literal_string_safe)

      parts = @ast.is_a?(AST::Sequence) ? @ast.parts : []
      quantifier, suffix = parts
      @hfa_possessive_literal_string_safe = if parts.length == 2 && quantifier.is_a?(AST::Quantifier) &&
                                               %i[+ *].include?(quantifier.kind) && quantifier.mode == :possessive &&
                                               quantifier.expression.is_a?(AST::Literal) && suffix.is_a?(AST::Literal) &&
                                               quantifier.expression.value.ascii_only? && suffix.value.ascii_only?
                                              true
                                            else
                                              false
                                            end
    end

    def hfa_possessive_literal_string_match_result(input, position)
      quantifier, suffix = @ast.parts
      unit = quantifier.expression.value
      unit_bytesize = unit.bytesize
      candidate = input.index(unit, position)
      while candidate
        finish = hfa_possessive_literal_run_end(input, candidate, unit, unit_bytesize)
        return [candidate, finish + suffix.value.bytesize, []] if input.byteslice(finish, suffix.value.bytesize) == suffix.value

        candidate = input.index(unit, candidate + 1)
      end
      nil
    end

    def hfa_possessive_literal_run_end(input, candidate, unit, unit_bytesize)
      finish = candidate
      if unit_bytesize == 1
        byte = unit.getbyte(0)
        finish += 1 while input.getbyte(finish) == byte
      else
        finish += unit_bytesize while input.byteslice(finish, unit_bytesize) == unit
      end
      finish
    end

    def hfa_bounded_sequence_direct_spec
      return @hfa_bounded_sequence_direct_spec if defined?(@hfa_bounded_sequence_direct_spec)

      parts = @ast.is_a?(AST::Sequence) ? @ast.parts : []
      quantifier_index = parts.index { |part| part.is_a?(AST::Quantifier) }
      @hfa_bounded_sequence_direct_spec = if quantifier_index == 1 && parts.length == 3
                                            prefix, quantifier, suffix = parts
                                            expression = quantifier.expression
                                            valid = quantifier.kind == :bounded &&
                                                    quantifier.mode == :greedy && quantifier.minimum >= 0 &&
                                                    quantifier.maximum && quantifier.maximum >= quantifier.minimum &&
                                                    prefix.is_a?(AST::Literal) && suffix.is_a?(AST::Literal) &&
                                                    prefix.value.ascii_only? && suffix.value.ascii_only? &&
                                                    !prefix.value.empty? && !suffix.value.empty? &&
                                                    (expression.is_a?(AST::Any) || expression.is_a?(AST::CharacterClass))
                                            if valid
                                              table = (ClassPredicates.compiled(expression.value).ascii_table if expression.is_a?(AST::CharacterClass))
                                              { prefix: prefix.value, suffix: suffix.value, minimum: quantifier.minimum,
                                                maximum: quantifier.maximum, table: table,
                                                allow_newline: @options.include?("multiline") }.freeze
                                            end
                                          end
      @hfa_bounded_sequence_direct_spec
    end

    def hfa_bounded_sequence_direct_match_result(input, position)
      spec = hfa_bounded_sequence_direct_spec
      binary = !input.ascii_only?
      source = binary ? input.b : input
      prefix = binary ? spec[:prefix].b : spec[:prefix]
      suffix = binary ? spec[:suffix].b : spec[:suffix]
      position = input.byteslice(0, position).bytesize if binary
      candidate = source.index(prefix, position)
      while candidate
        body_start = candidate + spec[:prefix].bytesize
        first_suffix = body_start + spec[:minimum]
        last_suffix = [body_start + spec[:maximum], input.bytesize - spec[:suffix].bytesize].min
        suffix_position = source.index(suffix, first_suffix)
        best = nil
        while suffix_position && suffix_position <= last_suffix
          span = suffix_position - body_start
          best = suffix_position if hfa_bounded_sequence_body_valid?(input, body_start, span, spec)
          suffix_position = source.index(suffix, suffix_position + 1)
        end
        return [candidate, best + spec[:suffix].bytesize, []] if best

        candidate = source.index(prefix, candidate + 1)
      end
      nil
    end

    def hfa_bounded_sequence_body_valid?(input, start, length, spec)
      return true if length.zero?
      return false if !spec[:allow_newline] && input.byteslice(start, length).include?("\n") && spec[:table].nil?
      return true unless spec[:table]

      length.times.all? { |offset| spec[:table][input.getbyte(start + offset)] }
    end

    def hfa_positive_lookbehind_literal_match_result(input, position)
      prefix, literal = hfa_literal_lookbehind_parts(:positive_lookbehind)
      candidate = input.b.index(literal.b, position)
      while candidate
        prefix_start = candidate - prefix.bytesize
        return [candidate, candidate + literal.bytesize, []] if prefix_start >= 0 &&
                                                                input.byteslice(prefix_start, prefix.bytesize) == prefix

        candidate = input.b.index(literal.b, candidate + 1)
      end
      nil
    end

    def hfa_literal_lookbehind_parts(kind)
      parts = @ast.is_a?(AST::Sequence) ? @ast.parts : []
      assertion = parts.first
      body = parts[1..]
      return unless assertion.is_a?(AST::Assertion) && assertion.kind == kind

      literal = body.map { |node| literal_ast_value(node) }
      guard = literal_ast_value(assertion.body)
      return unless guard&.bytesize&.positive? && literal.all?

      value = literal.join
      return unless value.bytesize.positive?

      kind == :positive_lookbehind ? [guard, value] : [value, guard]
    end

    def hfa_class_lookbehind_parts
      parts = @ast.is_a?(AST::Sequence) ? @ast.parts : []
      assertion = parts.first
      body = parts[1..]
      return unless assertion.is_a?(AST::Assertion) &&
                    %i[positive_lookbehind negative_lookbehind].include?(assertion.kind)
      return unless body.all? { |node| node.is_a?(AST::Literal) }

      guard = assertion.body
      guard = guard.parts.first if guard.is_a?(AST::Sequence) && guard.parts.one?
      return unless guard.is_a?(AST::CharacterClass)

      literal = body.map(&:value).join
      return if literal.empty?

      [assertion.kind, ClassPredicates.compiled(guard.value), literal].freeze
    end

    def hfa_casefold_class_lookbehind_parts
      return unless casefold?

      parts = @ast.is_a?(AST::Sequence) ? @ast.parts : []
      assertion = parts.first
      body = parts[1..]
      return unless assertion.is_a?(AST::Assertion) && assertion.kind == :positive_lookbehind
      return unless body.all? { |node| node.is_a?(AST::Literal) }

      guard = assertion.body
      guard = guard.parts.first if guard.is_a?(AST::Sequence) && guard.parts.one?
      return unless guard.is_a?(AST::CharacterClass) && guard.value.length.positive?

      literal = body.map(&:value).join
      return if literal.empty?

      [guard.value, literal].freeze
    end

    def hfa_class_lookbehind_match_result(input, position)
      kind, predicate, literal = hfa_class_lookbehind_parts
      candidate = input.b.index(literal.b, position)
      while candidate
        previous = hfa_previous_character(input, candidate)
        matches = previous && predicate.matches?(previous)
        matches = !matches if kind == :negative_lookbehind
        return [candidate, candidate + literal.bytesize, []] if matches

        candidate = input.b.index(literal.b, candidate + 1)
      end
      nil
    end

    def hfa_casefold_class_lookbehind_match_result(input, position)
      guard, literal = hfa_casefold_class_lookbehind_parts
      offsets = [0]
      input.each_char { |character| offsets << offsets[-1] + character.bytesize }
      candidate = input.b.index(literal.b, position)
      while candidate
        candidate_index = offsets.index(candidate)
        maximum_start = [candidate_index - (guard.length * 2), 0].max
        maximum_start.upto(candidate_index - 1) do |start_index|
          previous = input[start_index...candidate_index]
          return [candidate, candidate + literal.bytesize, []] if previous&.casecmp?(guard)
        end
        candidate = input.b.index(literal.b, candidate + 1)
      end
      nil
    end

    def hfa_previous_character(input, byte_position)
      return if byte_position.zero?

      start = byte_position - 1
      start -= 1 while start.positive? && (input.getbyte(start) & 0xc0) == 0x80
      input.byteslice(start, byte_position - start)
    end

    def hfa_negative_lookbehind_literal_match_result(input, position)
      literal, guard = hfa_literal_lookbehind_parts(:negative_lookbehind)
      candidate = input.b.index(literal.b, position)
      while candidate
        return [candidate, candidate + literal.bytesize, []] if candidate < guard.bytesize ||
                                                                input.byteslice(candidate - guard.bytesize, guard.bytesize) != guard

        candidate = input.b.index(literal.b, candidate + 1)
      end
      nil
    end

    def hfa_ignorecase_literal_match_result(input, position)
      literal = literal_ast_value(@ast)
      folded_input = input.downcase
      start = folded_input.index(literal.downcase, position)
      start && [start, start + literal.bytesize, []]
    end

    def hfa_ignorecase_literal_value
      return @hfa_ignorecase_literal_value if defined?(@hfa_ignorecase_literal_value)

      @hfa_ignorecase_literal_value = literal_ast_value(@ast)
    end

    def hfa_ignorecase_literal_variants
      return @hfa_ignorecase_literal_variants if defined?(@hfa_ignorecase_literal_variants)

      literal = hfa_ignorecase_literal_value
      @hfa_ignorecase_literal_variants = [literal.downcase, literal.upcase].uniq.freeze
    end

    def hfa_match_reset_literal_result_safe?
      return @hfa_match_reset_literal_safe if defined?(@hfa_match_reset_literal_safe)

      prefix, suffix = hfa_match_reset_literal_parts
      @hfa_match_reset_literal_safe = prefix&.ascii_only? && suffix&.ascii_only? &&
                                      prefix.bytesize.positive? && suffix.bytesize.positive?
    end

    def hfa_match_reset_literal_match_result(input, position)
      prefix, suffix = hfa_match_reset_literal_parts
      candidate = input.index(prefix, position)
      while candidate
        start = candidate + prefix.bytesize
        return [start, start + suffix.bytesize, []] if input.byteslice(start, suffix.bytesize) == suffix

        candidate = input.index(prefix, candidate + 1)
      end
      nil
    end

    def hfa_match_reset_literal_parts
      return @hfa_match_reset_literal_parts if defined?(@hfa_match_reset_literal_parts)

      parts = @ast.is_a?(AST::Sequence) ? @ast.parts : []
      reset = parts.index { |part| part.is_a?(AST::Escape) && part.kind == :match_reset }
      prefix = reset && literal_ast_value(AST::Sequence.new(parts[0...reset]))
      suffix = reset && literal_ast_value(AST::Sequence.new(parts[(reset + 1)..]))
      @hfa_match_reset_literal_parts = [prefix, suffix].freeze
    end

    def hfa_class_run_positive_lookahead_result_safe?
      return @hfa_class_run_positive_lookahead_safe if defined?(@hfa_class_run_positive_lookahead_safe)

      parts = @ast.is_a?(AST::Sequence) ? @ast.parts : []
      run, assertion = parts
      body = assertion.body if assertion.is_a?(AST::Assertion)
      guard = body.is_a?(AST::Sequence) ? body.parts : []
      valid = parts.length == 2 && run.is_a?(AST::Quantifier) && run.kind == :+ && run.mode == :greedy &&
              run.expression.is_a?(AST::CharacterClass) && assertion.is_a?(AST::Assertion) &&
              assertion.kind == :positive && guard.length == 2 && guard.first.is_a?(AST::Literal) &&
              guard.last.is_a?(AST::Quantifier) && guard.last.kind == :+ && guard.last.mode == :greedy &&
              guard.last.expression.is_a?(AST::CharacterClass)
      @hfa_class_run_positive_lookahead_safe = valid && !hfa_class_run_positive_lookahead_tables.nil?
    end

    def hfa_class_run_positive_lookahead_tables
      return @hfa_class_run_positive_lookahead_tables if defined?(@hfa_class_run_positive_lookahead_tables)

      run, assertion = @ast.parts
      guard = assertion.body.parts
      left = ClassPredicates.compiled(run.expression.value).ascii_table
      right = ClassPredicates.compiled(guard.last.expression.value).ascii_table
      @hfa_class_run_positive_lookahead_tables = [left, guard.first.value, right].freeze
    end

    def hfa_class_run_positive_lookahead_match_result(input, position)
      left_table, separator, right_table = hfa_class_run_positive_lookahead_tables
      separator_position = input.index(separator, position + 1)
      while separator_position
        left = separator_position
        left -= 1 while left > position && left_table[input.getbyte(left - 1)]
        right = separator_position + separator.bytesize
        return [left, separator_position, []] if left < separator_position &&
                                                 right < input.bytesize && right_table[input.getbyte(right)]

        separator_position = input.index(separator, separator_position + 1)
      end
      nil
    end

    def hfa_unicode_ignorecase_literal_result_safe?
      return @hfa_unicode_ignorecase_literal_safe if defined?(@hfa_unicode_ignorecase_literal_safe)

      literal = literal_ast_value(@ast)
      @hfa_unicode_ignorecase_literal_safe = if casefold? && literal &&
                                                !literal.ascii_only? && literal.bytesize.positive?
                                               true
                                             else
                                               false
                                             end
    end

    def hfa_unicode_ignorecase_literal_match_result(input, position, literal_value = nil)
      literal = (literal_value || hfa_unicode_ignorecase_literal_fold).downcase
      folded_input = input.downcase
      character_start = folded_input.index(literal, position)
      downcase_result = if character_start
                          character_finish = character_start + literal.length
                          [input[0, character_start].bytesize,
                           input[0, character_finish].bytesize, []]
                        end
      full_casefold_result = unless hfa_unicode_simple_casefold_literal?(literal)
                               hfa_unicode_full_casefold_literal_match_result(input, position, literal_value)
                             end
      [downcase_result, full_casefold_result].compact.min_by(&:first)
    end

    def hfa_unicode_simple_casefold_literal?(literal)
      literal.downcase == literal.upcase.downcase
    end

    def hfa_unicode_simple_casefold_each_result(input, literal)
      return false unless hfa_unicode_simple_casefold_literal?(literal)

      folded_input = input.downcase
      return false unless folded_input.length == input.length

      folded_literal = literal.downcase
      character_position = 0
      while (character_start = folded_input.index(folded_literal, character_position))
        character_finish = character_start + folded_literal.length
        yield [input[0, character_start].bytesize, input[0, character_finish].bytesize, []]
        character_position = character_finish
      end
      true
    end

    def hfa_unicode_full_casefold_literal_match_result(input, position, literal_value = nil)
      literal = literal_value || literal_ast_value(@ast)
      return unless literal

      maximum_length = [literal.length * 2, 1].max
      offsets = [0]
      input.each_char { |character| offsets << offsets[-1] + character.bytesize }
      input_length = offsets.length - 1
      position.upto(input_length - 1) do |character_start|
        maximum = [maximum_length, input_length - character_start].min
        1.upto(maximum) do |candidate_length|
          candidate = input[character_start, candidate_length]
          next unless candidate&.casecmp?(literal)

          return [offsets[character_start], offsets[character_start + candidate_length], []]
        end
      end
      nil
    end

    def hfa_unicode_ignorecase_literal_fold
      return @hfa_unicode_ignorecase_literal_fold if defined?(@hfa_unicode_ignorecase_literal_fold)

      @hfa_unicode_ignorecase_literal_fold = literal_ast_value(@ast)&.downcase
    end

    def hfa_repeated_literal_run_match_result(input, position)
      unit = @ast.parts.first.expression.value
      candidate = input.index(unit, position)
      while candidate
        finish = candidate
        finish += unit.bytesize while input.byteslice(finish, unit.bytesize) == unit
        return [candidate, finish, []] if finish > candidate

        candidate = input.index(unit, candidate + 1)
      end
      nil
    end

    def hfa_lazy_literal_result_safe?
      return @hfa_lazy_literal_safe if defined?(@hfa_lazy_literal_safe)

      parts = @ast.is_a?(AST::Sequence) ? @ast.parts : []
      quantifier = parts.first
      unless quantifier.is_a?(AST::Quantifier)
        @hfa_lazy_literal_safe = false
        return @hfa_lazy_literal_safe
      end
      suffix = if parts.length == 1
                 nil
               else
                 parts[1..].map { |part| literal_ast_value(part) }.then { |values| values.all? ? values.join : nil }
               end
      valid = parts.length <= 2 && quantifier.is_a?(AST::Quantifier) &&
              %i[+ ?].include?(quantifier.kind) && quantifier.mode == :lazy &&
              quantifier.expression.is_a?(AST::Literal) && quantifier.expression.value.ascii_only? &&
              quantifier.expression.value.bytesize.positive? &&
              (suffix.nil? || (suffix.ascii_only? && suffix.bytesize.positive?)) &&
              !casefold?
      @hfa_lazy_literal_safe = valid ? [quantifier.kind, quantifier.expression.value, suffix].freeze : false
    end

    def hfa_lazy_literal_match_result(input, position)
      kind, literal, suffix = hfa_lazy_literal_result_safe?
      if kind == :+
        candidate = input.index(literal, position)
        while candidate
          cursor = candidate + literal.bytesize
          loop do
            return [candidate, cursor, []] if suffix.nil?
            return [candidate, cursor + suffix.bytesize, []] if input.byteslice(cursor, suffix.bytesize) == suffix

            break unless input.byteslice(cursor, literal.bytesize) == literal

            cursor += literal.bytesize
          end
          candidate = input.index(literal, candidate + 1)
        end
        return nil
      end

      cursor = position
      while cursor <= input.bytesize
        return [cursor, cursor + suffix.bytesize, []] if input.byteslice(cursor, suffix.bytesize) == suffix
        if input.byteslice(cursor, literal.bytesize) == literal &&
           input.byteslice(cursor + literal.bytesize, suffix.bytesize) == suffix
          return [cursor, cursor + literal.bytesize + suffix.bytesize, []]
        end

        cursor += 1
      end
      nil
    end

    def hfa_repeated_class_backref_result_safe?
      return @hfa_repeated_class_backref_safe if defined?(@hfa_repeated_class_backref_safe)

      table, separator = hfa_repeated_class_backref_parts
      @hfa_repeated_class_backref_safe = !table.nil? && separator&.ascii_only? && separator.bytesize.positive?
    end

    def hfa_repeated_class_backref_parts
      return @hfa_repeated_class_backref_parts if defined?(@hfa_repeated_class_backref_parts)

      parts = @ast.is_a?(AST::Sequence) ? @ast.parts : []
      group, separator, backref = parts
      body = group.body if group.is_a?(AST::Group)
      body = body.parts.first if body.is_a?(AST::Sequence) && body.parts.one?
      quantifier = body if body.is_a?(AST::Quantifier) && body.kind == :+ && body.mode == :greedy
      expression = quantifier&.expression
      separator_value = separator.value if separator.is_a?(AST::Literal)
      table = if group.is_a?(AST::Group) && group.capture && backref.is_a?(AST::Backreference) &&
                 backref.identifier == group.number && separator.is_a?(AST::Literal) &&
                 (expression.is_a?(AST::CharacterClass) || expression.is_a?(AST::Escape))
                hfa_capture_class_table(expression)
              end
      @hfa_repeated_class_backref_parts = [table, separator_value].freeze
    end

    def hfa_repeated_class_backref_match_result(input, position)
      table, separator = hfa_repeated_class_backref_parts
      separator_position = input.index(separator, position + 1)
      while separator_position
        left = separator_position
        left -= 1 while left > position && table[input.getbyte(left - 1)]
        length = separator_position - left
        if length.positive? && input.byteslice(separator_position + separator.bytesize, length) ==
                               input.byteslice(left, length)
          group = @ast.parts.first
          captures = Array.new(group.number)
          captures[group.number - 1] = [left, separator_position]
          return [left, separator_position + separator.bytesize + length, captures]
        end

        separator_position = input.index(separator, separator_position + 1)
      end
      nil
    end

    def hfa_repeated_equal_length_literal_capture_result_safe?
      return @hfa_repeated_equal_length_capture_safe if defined?(@hfa_repeated_equal_length_capture_safe)

      parts = @ast.is_a?(AST::Sequence) ? @ast.parts : []
      repeat, suffix = parts
      group = repeat.expression if repeat.is_a?(AST::Quantifier)
      body = group.body if group.is_a?(AST::Group) && group.capture
      values = body.branches.map { |branch| literal_ast_value(branch) } if body.is_a?(AST::Alternation)
      valid = parts.length == 2 && repeat.is_a?(AST::Quantifier) && repeat.kind == :+ &&
              repeat.mode == :greedy && group.is_a?(AST::Group) && group.capture &&
              values&.all? { |value| value&.ascii_only? && value.bytesize.positive? } &&
              values.map(&:bytesize).uniq.one? && suffix.is_a?(AST::Literal) &&
              !casefold?
      @hfa_repeated_equal_length_capture_safe = if valid && hfa_program
                                                  [group.number, values.first.bytesize, suffix.value].freeze
                                                else
                                                  false
                                                end
    end

    def hfa_repeated_equal_length_literal_capture_match_result(input, position, program_result = nil)
      number, unit_length, suffix = hfa_repeated_equal_length_literal_capture_result_safe?
      result = program_result || hfa_program.match_result(input, position)
      return unless result

      start, finish, = result
      repeat_finish = finish - suffix.bytesize
      capture_start = repeat_finish - unit_length
      captures = Array.new(number)
      captures[number - 1] = [capture_start, repeat_finish]
      [start, finish, captures]
    end

    def hfa_literal_capture_before_alternation_result_safe?
      return @hfa_literal_capture_before_alternation_safe if defined?(@hfa_literal_capture_before_alternation_safe)

      parts = @ast.is_a?(AST::Sequence) ? @ast.parts : []
      capture_group, alternation_group = parts
      literal = capture_group.body if capture_group.is_a?(AST::Group) && capture_group.capture
      literal = literal_ast_value(literal)
      alternation = alternation_group.body if alternation_group.is_a?(AST::Group) && !alternation_group.capture
      values = alternation.branches.map { |branch| literal_ast_value(branch) } if alternation.is_a?(AST::Alternation)
      valid = parts.length == 2 && literal&.ascii_only? && literal.bytesize.positive? &&
              values&.all? { |value| value&.ascii_only? && value.bytesize.positive? } &&
              !casefold?
      @hfa_literal_capture_before_alternation_safe = if valid && hfa_program
                                                       [capture_group.number, literal].freeze
                                                     else
                                                       false
                                                     end
    end

    def hfa_literal_capture_before_alternation_match_result(input, position, program_result = nil)
      number, literal = hfa_literal_capture_before_alternation_result_safe?
      result = program_result || hfa_program.match_result(input, position)
      return unless result

      start, finish, = result
      captures = Array.new(number)
      captures[number - 1] = [start, start + literal.bytesize]
      [start, finish, captures]
    end

    def hfa_adjacent_greedy_capture_result_safe?
      return @hfa_adjacent_greedy_capture_safe if defined?(@hfa_adjacent_greedy_capture_safe)

      parts = @ast.is_a?(AST::Sequence) ? @ast.parts : []
      first, second = parts
      first_body = first.body if first.is_a?(AST::Group)
      second_body = second.body if second.is_a?(AST::Group)
      first_quantifier = first_body.parts.one? && first_body.parts.first if first_body.is_a?(AST::Sequence)
      second_quantifier = second_body.parts.one? && second_body.parts.first if second_body.is_a?(AST::Sequence)
      valid = parts.length == 2 && [first, second].all? { |node| node.is_a?(AST::Group) && node.capture } &&
              first_quantifier.is_a?(AST::Quantifier) && second_quantifier.is_a?(AST::Quantifier) &&
              first_quantifier.kind == :* && second_quantifier.kind == :* &&
              first_quantifier.mode == :greedy && second_quantifier.mode == :greedy &&
              first_quantifier.expression == second_quantifier.expression &&
              (first_quantifier.expression.is_a?(AST::Literal) || first_quantifier.expression.is_a?(AST::Any)) &&
              !casefold?
      @hfa_adjacent_greedy_capture_safe = valid && hfa_program
    end

    def hfa_unicode_repeated_literal_capture_result_safe?
      return @hfa_unicode_repeated_capture_safe if defined?(@hfa_unicode_repeated_capture_safe)

      parts = @ast.is_a?(AST::Sequence) ? @ast.parts : []
      group = parts.one? && parts.first
      body = group.body if group.is_a?(AST::Group) && group.capture
      body = body.parts.one? && body.parts.first if body.is_a?(AST::Sequence)
      valid = group.is_a?(AST::Group) && body.is_a?(AST::Quantifier) && body.kind == :+ &&
              body.mode == :greedy && body.expression.is_a?(AST::Literal) &&
              !body.expression.value.ascii_only? && !casefold?
      @hfa_unicode_repeated_capture_safe = valid
    end

    def hfa_unicode_repeated_literal_capture_match_result(input, position)
      literal = @ast.parts.first.body.parts.first.expression.value
      start = input.byteindex(literal, position)
      return nil unless start

      finish = start + literal.bytesize
      finish += literal.bytesize while input.byteslice(finish, literal.bytesize) == literal
      [start, finish, [[start, finish]]]
    end

    def hfa_unicode_repeated_literal_capture_match_data(result, input)
      start, finish, = result
      start_character, finish_character = hfa_unicode_repeated_literal_capture_character_offsets(input, start, finish)
      value = input.byteslice(start, finish - start)
      names = hfa_result_names
      MatchData.new(value, [value], [[start_character, finish_character], [start_character, finish_character]],
                    names, MatchData::Context.new(input, self))
    end

    def hfa_unicode_repeated_literal_capture_character_offsets(input, start, finish)
      literal = @ast.parts.first.body.parts.first.expression.value
      start_character = input.byteslice(0, start).to_s.length
      repetitions = (finish - start) / literal.bytesize
      [start_character, start_character + repetitions * literal.length]
    end

    def hfa_adjacent_greedy_capture_end(input, start, finish)
      expression = @ast.parts.first.body.parts.first.expression
      cursor = start
      if expression.is_a?(AST::Literal)
        literal = expression.value
        cursor += literal.bytesize while cursor < finish && input.byteslice(cursor, literal.bytesize) == literal
      elsif expression.is_a?(AST::Any)
        while cursor < finish
          break if !@options.include?("multiline") && input.getbyte(cursor) == 10

          cursor += 1
        end
      end
      cursor
    end

    def hfa_unicode_property_run_result_safe?
      return @hfa_unicode_property_run_safe if defined?(@hfa_unicode_property_run_safe)

      node = @ast.is_a?(AST::Sequence) && @ast.parts.one? ? @ast.parts.first : nil
      safe = !casefold? && node.is_a?(AST::Quantifier) &&
             node.kind == :+ && node.mode == :greedy &&
             node.expression.is_a?(AST::Property) &&
             !hfa_unicode_property_run_spec.nil?
      @hfa_unicode_match_safe = true if safe
      @hfa_unicode_property_run_safe = safe
    end

    def hfa_unicode_property_run_spec
      return @hfa_unicode_property_run_spec if defined?(@hfa_unicode_property_run_spec)

      node = @ast.parts.first.expression
      normalized = node.name.sub("Is", "").sub("^", "")
      matcher = UnicodeProperties::PROPERTY_MATCHERS[normalized]
      @hfa_unicode_property_run_spec = matcher && [UnicodeProperties.method(matcher), node.negated].freeze
    end

    def hfa_unicode_property_run_match_result(input, position)
      predicate, negated = hfa_unicode_property_run_spec
      property_name = @ast.parts.first.expression.name.sub("Is", "").sub("^", "")
      return hfa_unicode_hiragana_run_match_result(input, position, negated) if property_name == "Hiragana"
      return hfa_unicode_letter_property_run_match_result(input, position, negated) if %w[Letter Alpha].include?(property_name)

      matcher = hfa_unicode_property_run_matcher
      cursor = 0
      start = nil
      hfa_unicode_property_codepoint_events(input) do |codepoint, bytesize|
        matched = cursor >= position && (matcher.call(codepoint, predicate) ^ negated)
        if matched
          start ||= cursor
        elsif start
          return [start, cursor, []]
        end
        cursor += bytesize
      end
      start && [start, cursor, []]
    end

    def hfa_unicode_hiragana_run_match_result(input, position, negated)
      cursor = 0
      start = nil
      hfa_unicode_property_codepoint_events(input) do |codepoint, bytesize|
        matched = cursor >= position && (codepoint.between?(0x3040, 0x309f) ^ negated)
        if matched
          start ||= cursor
        elsif start
          return [start, cursor, []]
        end
        cursor += bytesize
      end
      start && [start, cursor, []]
    end

    def hfa_unicode_letter_property_run_match_result(input, position, negated)
      cursor = 0
      start = nil
      hfa_unicode_property_codepoint_events(input) do |codepoint, bytesize|
        matched = cursor >= position && (hfa_unicode_letter_codepoint?(codepoint) ^ negated)
        if matched
          start ||= cursor
        elsif start
          return [start, cursor, []]
        end
        cursor += bytesize
      end
      start && [start, cursor, []]
    end

    def hfa_unicode_letter_codepoint?(codepoint)
      return true if codepoint.between?(65, 90) || codepoint.between?(97, 122)
      return true if codepoint.between?(0x3040, 0x30ff) || codepoint.between?(0x3400, 0x4dbf) ||
                     codepoint.between?(0x4e00, 0x9fff) || codepoint.between?(0xac00, 0xd7af)

      UnicodeProperties.letter?(codepoint.chr(Encoding::UTF_8))
    end

    def utf8_codepoint_bytesize(codepoint)
      return 1 if codepoint <= 0x7f
      return 2 if codepoint <= 0x7ff
      return 3 if codepoint <= 0xffff

      4
    end

    def hfa_unicode_property_run_matcher
      return @hfa_unicode_property_run_matcher if defined?(@hfa_unicode_property_run_matcher)

      name = @ast.parts.first.expression.name.sub("Is", "").sub("^", "")
      @hfa_unicode_property_run_matcher = case name
                                          when "Hiragana"
                                            ->(codepoint, _predicate) { codepoint.between?(0x3040, 0x309f) }
                                          when "Letter", "Alpha"
                                            lambda do |codepoint, predicate|
                                              return true if codepoint.between?(65, 90) || codepoint.between?(97, 122)
                                              return true if codepoint.between?(0x3040, 0x30ff) ||
                                                             codepoint.between?(0x3400, 0x4dbf) ||
                                                             codepoint.between?(0x4e00, 0x9fff) ||
                                                             codepoint.between?(0xac00, 0xd7af)

                                              predicate.call(codepoint.chr(Encoding::UTF_8))
                                            end
                                          else
                                            ->(codepoint, predicate) { predicate.call(codepoint.chr(Encoding::UTF_8)) }
                                          end
    end

    def hfa_unicode_repeated_literal_result_safe?
      return @hfa_unicode_repeated_literal_safe if defined?(@hfa_unicode_repeated_literal_safe)

      @hfa_unicode_repeated_literal_safe = if casefold? ||
                                              !@ast.is_a?(AST::Sequence) || !@ast.parts.one?
                                             false
                                           else
                                             quantifier = @ast.parts.first
                                             if quantifier.is_a?(AST::Quantifier) && quantifier.kind == :+ &&
                                                quantifier.mode == :greedy
                                               literal = hfa_unicode_repeated_literal_unit
                                               literal&.bytesize&.positive? && !literal.ascii_only?
                                             end
                                           end
    end

    def hfa_unicode_repeated_literal_match_result(input, position)
      unit = hfa_unicode_repeated_literal_unit
      unit_bytesize = unit.bytesize
      candidate = input.b.index(unit.b, position)
      while candidate
        finish = candidate
        finish += unit_bytesize while input.byteslice(finish, unit_bytesize) == unit
        return [candidate, finish, []] if finish > candidate

        candidate = input.byteindex(unit, candidate + 1)
      end
      nil
    end

    def hfa_unicode_repeated_literal_unit
      return @hfa_unicode_repeated_literal_unit if defined?(@hfa_unicode_repeated_literal_unit)

      quantifier = @ast.is_a?(AST::Sequence) && @ast.parts.first
      expression = quantifier.expression if quantifier.is_a?(AST::Quantifier)
      expression = expression.body if expression.is_a?(AST::Group)
      @hfa_unicode_repeated_literal_unit = literal_ast_value(expression)
    end

    def class_run_result_node?(node)
      node.is_a?(AST::Quantifier) && node.kind == :+ &&
        (node.expression.is_a?(AST::CharacterClass) || node.expression.is_a?(AST::Any) ||
         node.expression.is_a?(AST::Escape) && %i[digit space word].include?(node.expression.kind) ||
         node.expression.is_a?(AST::Property) && UnicodeProperties::SUPPORTED.include?(node.expression.name.sub("Is", "").sub(
                                                                                         "^", ""
                                                                                       )))
    end

    def star_literal_result_node?(node)
      node.is_a?(AST::Quantifier) && node.kind == :* && node.mode == :greedy &&
        node.expression.is_a?(AST::Any)
    end

    def star_literal_ast?
      return false unless @ast.is_a?(AST::Sequence) && @ast.parts.length == 3

      @ast.parts[0].is_a?(AST::Literal) && star_literal_result_node?(@ast.parts[1]) &&
        @ast.parts[2].is_a?(AST::Literal)
    end

    def lazy_star_literal_ast?
      return false unless @ast.is_a?(AST::Sequence) && @ast.parts.length == 3

      prefix, quantifier, suffix = @ast.parts
      prefix.is_a?(AST::Literal) && quantifier.is_a?(AST::Quantifier) &&
        quantifier.kind == :* && quantifier.mode == :lazy && quantifier.expression.is_a?(AST::Any) &&
        suffix.is_a?(AST::Literal)
    end

    def literal_class_literal_ast?
      return false unless @ast.is_a?(AST::Sequence) && @ast.parts.length == 3

      prefix, run, suffix = @ast.parts
      prefix.is_a?(AST::Literal) && class_run_result_node?(run) && suffix.is_a?(AST::Literal) &&
        selective_class_run_node?(run)
    end

    def selective_class_run_node?(node)
      return true if node.expression.is_a?(AST::Any)
      return true if node.expression.is_a?(AST::Property) &&
                     UnicodeProperties::SUPPORTED.include?(node.expression.name.sub("Is", "").sub("^", ""))

      table = if node.expression.is_a?(AST::Escape)
                256.times.count do |byte|
                  CharacterPredicates.escape_matches?(node.expression.kind, byte.chr(Encoding::ASCII_8BIT))
                end
              elsif node.expression.is_a?(AST::Property)
                256.times.count do |byte|
                  matched = UnicodeProperties.matches?(node.expression.name,
                                                       byte.chr(Encoding::ASCII_8BIT))
                  node.expression.negated ? !matched : matched
                end
              else
                ClassPredicates.compiled(node.expression.value).ascii_table.count(true)
              end
      table <= 16
    end

    def hfa_match_data(result, input)
      return nil unless result

      start, finish, captures = result
      return MatchData.from_byte_offsets(input, start, finish, captures, hfa_result_names, self) if hfa_literal_capture_sequence_spec && captures.any?

      if captures.empty? && (strategy = hfa_capture_offset_strategy)
        capture_offsets = case strategy
                          when :simple then hfa_simple_capture_offsets(input, start, finish)
                          when :nested_literal then hfa_nested_literal_capture_offsets(input, start, finish)
                          when :nested_repeated then hfa_nested_repeated_capture_offsets(input, start, finish)
                          when :adjacent_nested_repeated
                            hfa_adjacent_nested_repeated_capture_offsets(input, start, finish)
                          when :repeated_class then hfa_repeated_class_capture_offsets(input, start, finish)
                          when :conditional then hfa_conditional_capture_offsets(input, start)
                          when :subexpression then hfa_subexpression_capture_offsets(input, start)
                          end
        if capture_offsets
          names = if strategy == :simple
                    hfa_static_capture_names || hfa_capture_names.transform_values do |indices|
                      indices.reverse_each.find { |index| capture_offsets[index - 1] } || indices.last
                    end
                  else
                    hfa_static_capture_names || hfa_result_names
                  end
          return hfa_offset_match_data(input, start, finish, capture_offsets, names)
        end
      end
      if captures.empty? && hfa_capture_count.positive?
        capture_offsets = hfa_whole_capture_offsets(start, finish)
        return hfa_offset_match_data(input, start, finish, capture_offsets, hfa_result_names) if capture_offsets
      end
      if captures.any? && captures.all? { |capture| capture.nil? || (capture.is_a?(Array) && capture.length == 2) }
        return hfa_offset_match_data(input, start, finish, captures, hfa_result_names)
      end
      return MatchData.captureless(input, start, finish, self) if captures.empty?

      MatchData.new(input[start...finish], captures, [[start, finish]], {},
                    MatchData::Context.new(input, self))
    end

    def hfa_capture_offset_strategy
      return @hfa_capture_offset_strategy if defined?(@hfa_capture_offset_strategy)

      @hfa_capture_offset_strategy = if hfa_simple_capture_layout
                                       :simple
                                     elsif hfa_nested_literal_capture_result_safe?
                                       :nested_literal
                                     elsif hfa_nested_repeated_capture_result_safe?
                                       :nested_repeated
                                     elsif hfa_adjacent_nested_repeated_capture_result_safe?
                                       :adjacent_nested_repeated
                                     elsif hfa_repeated_class_capture_result_safe?
                                       :repeated_class
                                     elsif hfa_conditional_result_safe?
                                       :conditional
                                     elsif hfa_subexpression_result_safe?
                                       :subexpression
                                     else
                                       false
                                     end
    end

    def hfa_tagged_capture_result(input, result, strategy)
      start, finish, captures = result
      offsets = case strategy
                when :simple
                  (hfa_top_level_capture_offsets(input, start, finish) if hfa_top_level_capture_plan) ||
                  hfa_simple_capture_offsets(input, start, finish)
                when :nested_literal then hfa_nested_literal_capture_offsets(input, start, finish)
                when :nested_repeated then hfa_nested_repeated_capture_offsets(input, start, finish)
                when :adjacent_nested_repeated then hfa_adjacent_nested_repeated_capture_offsets(input, start, finish)
                when :repeated_class then hfa_repeated_class_capture_offsets(input, start, finish)
                when :conditional then hfa_conditional_capture_offsets(input, start)
                when :subexpression then hfa_subexpression_capture_offsets(input, start)
                end
      [start, finish, offsets || captures]
    end

    def hfa_offset_match_data(input, start, finish, capture_offsets, names)
      MatchData.from_offsets(input, start, finish, capture_offsets, names, self)
    end

    def hfa_conditional_capture_offsets(input, start)
      return unless hfa_conditional_result_safe?

      optional = @ast.parts.first
      value = literal_ast_value(optional.expression.body)
      return unless value

      captured = input.byteslice(start, value.bytesize) == value
      [captured ? [start, start + value.bytesize] : nil]
    end

    def hfa_subexpression_capture_offsets(input, start)
      return unless hfa_subexpression_result_safe?

      group = @ast.parts.first
      value = literal_ast_value(group.body)
      return unless value && input.byteslice(start, value.bytesize) == value

      offsets = Array.new(group.number)
      offsets[group.number - 1] = [start, start + value.bytesize]
      offsets
    end

    def hfa_nested_literal_capture_offsets(input, start, finish)
      return unless hfa_nested_literal_capture_result_safe?

      captures = []
      value = hfa_nested_literal_value(@ast, captures)
      matched_length = hfa_nested_literal_match_length(@ast, input, start)
      return unless value && matched_length && start + matched_length == finish

      offsets = Array.new(captures.map(&:first).max)
      hfa_collect_nested_capture_offsets(@ast, input, start, offsets)
      offsets
    end

    def value_for_capture(captures, number)
      captures.reverse_each { |capture_number, value| return value if capture_number == number }
      ""
    end

    def hfa_nested_literal_value(node, captures)
      case node
      when AST::Literal
        node.value
      when AST::Group
        value = hfa_nested_literal_value(node.body, captures)
        captures << [node.number, value] if value && node.capture
        value
      when AST::Sequence
        values = node.parts.map { |part| hfa_nested_literal_value(part, captures) }
        values.all? ? values.join : nil
      when AST::Alternation
        values = node.branches.map { |branch| hfa_nested_literal_value(branch, []) }
        values.all? ? values.first : nil
      end
    end

    def hfa_nested_literal_match_length(node, input, position)
      case node
      when AST::Literal
        input.byteslice(position, node.value.bytesize) == node.value ? node.value.bytesize : nil
      when AST::Group
        hfa_nested_literal_match_length(node.body, input, position)
      when AST::Sequence
        cursor = position
        node.parts.each do |part|
          length = hfa_nested_literal_match_length(part, input, cursor)
          return unless length

          cursor += length
        end
        cursor - position
      when AST::Alternation
        node.branches.filter_map { |branch| hfa_nested_literal_match_length(branch, input, position) }.first
      end
    end

    def hfa_collect_nested_capture_offsets(node, input, position, offsets)
      case node
      when AST::Group
        length = hfa_nested_literal_match_length(node.body, input, position)
        return unless length

        offsets[node.number - 1] = [position, position + length] if node.capture
        hfa_collect_nested_capture_offsets(node.body, input, position, offsets)
      when AST::Sequence
        cursor = position
        node.parts.each do |part|
          length = hfa_nested_literal_match_length(part, input, cursor)
          return unless length

          hfa_collect_nested_capture_offsets(part, input, cursor, offsets)
          cursor += length
        end
      when AST::Alternation
        node.branches.each do |branch|
          length = hfa_nested_literal_match_length(branch, input, position)
          next unless length

          hfa_collect_nested_capture_offsets(branch, input, position, offsets)
          break
        end
      end
    end

    def hfa_simple_capture_layout
      return @hfa_simple_capture_layout if defined?(@hfa_simple_capture_layout)

      parts = @ast.is_a?(AST::Sequence) ? @ast.parts : [@ast]
      captures = parts.filter_map do |part|
        component = hfa_capture_component(part)
        component && component[2]
      end
      @hfa_simple_capture_layout = if captures.empty?
                                     false
                                   else
                                     layout = parts.map { |part| hfa_capture_component(part) }
                                     if layout.all?
                                       variable = layout.each_with_index.any? do |(kind, value, _number), index|
                                         kind == :alternation_literal && value.map(&:bytesize).uniq.length > 1 &&
                                           index == layout.length - 1
                                       end
                                       variable ? false : layout.freeze
                                     else
                                       false
                                     end
                                   end
    end

    def hfa_simple_capture_count
      return @hfa_simple_capture_count if defined?(@hfa_simple_capture_count)

      layout = hfa_simple_capture_layout
      @hfa_simple_capture_count = layout ? (layout.filter_map { |_kind, _value, number| number }.max || 0) : 0
    end

    def hfa_empty_nested_capture_spec
      return @hfa_empty_nested_capture_spec if defined?(@hfa_empty_nested_capture_spec)

      parts = @ast.is_a?(AST::Sequence) ? @ast.parts : []
      outer = parts.first
      suffix = parts[1..]
      group = outer.expression if outer.is_a?(AST::Quantifier) && outer.kind == :* && outer.mode == :greedy
      body = group.body if group.is_a?(AST::Group) && group.capture
      body = body.parts.first if body.is_a?(AST::Sequence) && body.parts.one?
      inner = body if body.is_a?(AST::Quantifier) && body.kind == :* && body.mode == :greedy
      unit = inner.expression if inner
      literal = unit.value if unit.is_a?(AST::Literal)
      suffix_value = suffix&.map { |node| node.value if node.is_a?(AST::Literal) }&.then do |values|
        values.all? ? values.join : nil
      end
      @hfa_empty_nested_capture_spec = if group && literal&.ascii_only? && literal.bytesize == 1 &&
                                          suffix_value&.ascii_only? && suffix_value.bytesize.positive?
                                         [group.number, suffix_value].freeze
                                       else
                                         false
                                       end
    end

    def hfa_empty_nested_capture_match_result(input, position)
      number, suffix = hfa_empty_nested_capture_spec
      result = hfa_program.match_result(input, position)
      return unless result

      capture_position = result[1] - suffix.bytesize
      captures = Array.new(number)
      captures[number - 1] = [capture_position, capture_position]
      [result[0], result[1], captures]
    end

    def hfa_variable_subexpression_capture_spec
      return @hfa_variable_subexpression_capture_spec if defined?(@hfa_variable_subexpression_capture_spec)

      parts = @ast.is_a?(AST::Sequence) ? @ast.parts : []
      group, separator, call, suffix = parts
      branches = if group.is_a?(AST::Group) && group.capture && group.body.is_a?(AST::Alternation)
                   group.body.branches.map { |branch| literal_ast_value(branch) }
                 end
      @hfa_variable_subexpression_capture_spec = if branches&.all? && group.name &&
                                                    call.is_a?(AST::SubexpressionCall) &&
                                                    call.identifier.to_s == group.name.to_s &&
                                                    separator.is_a?(AST::Literal) && suffix.is_a?(AST::Literal)
                                                   [branches.freeze, separator.value, suffix.value, group.number].freeze
                                                 else
                                                   false
                                                 end
    end

    def hfa_variable_subexpression_capture_match_result(input, position)
      branches, separator, suffix, number = hfa_variable_subexpression_capture_spec
      result = hfa_program.match_result(input, position)
      return unless result

      start, finish, = result
      branch = branches.find do |value|
        expected = value + separator + value + suffix
        expected.bytesize == finish - start && input.byteslice(start, expected.bytesize) == expected
      end
      return unless branch

      captures = Array.new(number)
      captures[number - 1] = [start, start + branch.bytesize]
      [start, finish, captures]
    end

    def hfa_variable_capture_alternation_spec
      return @hfa_variable_capture_alternation_spec if defined?(@hfa_variable_capture_alternation_spec)

      parts = @ast.is_a?(AST::Sequence) ? @ast.parts : []
      groups = parts if parts.length == 2 && parts.all? { |part| part.is_a?(AST::Group) && part.capture }
      branches = groups&.map do |group|
        next unless group.body.is_a?(AST::Alternation)

        group.body.branches.map { |branch| literal_ast_value(branch) }
      end
      @hfa_variable_capture_alternation_spec = if branches&.all? && branches.all? do |values|
        values.all? { |value| value&.ascii_only? && value.bytesize.positive? }
      end
                                                 [branches.freeze, groups.map(&:number).freeze].freeze
                                               else
                                                 false
                                               end
    end

    def hfa_variable_capture_alternation_match_result(input, position)
      branches, numbers = hfa_variable_capture_alternation_spec
      cursor = position
      while cursor <= input.bytesize
        branches[0].each do |left|
          branches[1].each do |right|
            finish = cursor + left.bytesize + right.bytesize
            next unless input.byteslice(cursor, finish - cursor) == left + right

            captures = Array.new(numbers.max)
            captures[numbers[0] - 1] = [cursor, cursor + left.bytesize]
            captures[numbers[1] - 1] = [cursor + left.bytesize, finish]
            return [cursor, finish, captures]
          end
        end
        cursor += 1
      end
      nil
    end

    def hfa_nested_literal_capture_alternation_spec
      return @hfa_nested_literal_capture_alternation_spec if defined?(@hfa_nested_literal_capture_alternation_spec)

      parts = @ast.is_a?(AST::Sequence) ? @ast.parts : []
      outer, suffix = parts
      alternation = outer.body if outer.is_a?(AST::Group) && !outer.capture &&
                                  outer.body.is_a?(AST::Alternation)
      branches = alternation&.branches&.map do |branch|
        group = branch.parts.one? && branch.parts.first if branch.is_a?(AST::Sequence)
        value = group.body if group.is_a?(AST::Group) && group.capture
        [literal_ast_value(value), group&.number]
      end
      valid = parts.length == 2 && suffix.is_a?(AST::Literal) && branches&.all? do |value, number|
        value&.ascii_only? && value.bytesize.positive? && number
      end
      @hfa_nested_literal_capture_alternation_spec = if valid && suffix.value.ascii_only? &&
                                                        suffix.value.bytesize.positive?
                                                       [branches.freeze, suffix.value].freeze
                                                     else
                                                       false
                                                     end
    end

    def hfa_nested_literal_capture_alternation_match_result(input, position, program_result = nil)
      branches, suffix = hfa_nested_literal_capture_alternation_spec
      result = program_result || hfa_program.match_result(input, position)
      return unless result

      start, finish, = result
      value, number = branches.find do |branch, _capture_number|
        branch.bytesize + suffix.bytesize == finish - start &&
          input.byteslice(start, branch.bytesize) == branch &&
          input.byteslice(start + branch.bytesize, suffix.bytesize) == suffix
      end
      return unless value

      captures = Array.new(branches.map(&:last).max)
      captures[number - 1] = [start, start + value.bytesize]
      [start, finish, captures]
    end

    def hfa_lookahead_alternation_backreference_spec
      return @hfa_lookahead_alternation_backreference_spec if defined?(@hfa_lookahead_alternation_backreference_spec)

      parts = @ast.is_a?(AST::Sequence) ? @ast.parts : []
      assertion, backref, suffix = parts
      group = if assertion.is_a?(AST::Assertion) && assertion.kind == :positive
                body = assertion.body
                body = body.parts.first if body.is_a?(AST::Sequence) && body.parts.one?
                body if body.is_a?(AST::Group) && body.capture && body.body.is_a?(AST::Alternation)
              end
      branches = group&.body&.branches&.map { |branch| literal_ast_value(branch) }
      @hfa_lookahead_alternation_backreference_spec = if branches&.all? &&
                                                         branches.all? { |value| value&.ascii_only? && value.bytesize.positive? } &&
                                                         backref.is_a?(AST::Backreference) &&
                                                         backref.identifier.to_i == group.number && suffix.is_a?(AST::Literal)
                                                        [branches.freeze, suffix.value, group.number].freeze
                                                      else
                                                        false
                                                      end
    end

    def hfa_lookahead_literal_backreference_spec
      return @hfa_lookahead_literal_backreference_spec if defined?(@hfa_lookahead_literal_backreference_spec)

      parts = @ast.is_a?(AST::Sequence) ? @ast.parts : []
      assertion, backref = parts
      group = if assertion.is_a?(AST::Assertion) && assertion.kind == :positive
                body = assertion.body
                body = body.parts.first if body.is_a?(AST::Sequence) && body.parts.one?
                body if body.is_a?(AST::Group) && body.capture
              end
      literal = literal_ast_value(group&.body)
      @hfa_lookahead_literal_backreference_spec = if parts.length == 2 && literal&.ascii_only? && literal.bytesize.positive? &&
                                                     backref.is_a?(AST::Backreference) &&
                                                     (backref.identifier.to_i == group.number ||
                                                      backref.identifier.to_s == group.name.to_s)
                                                    [literal.freeze, group.number].freeze
                                                  else
                                                    false
                                                  end
    end

    def hfa_lookahead_literal_backreference_match_result(input, position, spec)
      literal, number = spec
      start = input.index(literal, position)
      return unless start

      finish = start + literal.bytesize
      captures = Array.new(number)
      captures[number - 1] = [start, finish]
      [start, finish, captures]
    end

    def hfa_lookahead_alternation_backreference_match_result(input, position)
      branches, suffix, number = hfa_lookahead_alternation_backreference_spec
      cursor = position
      while cursor <= input.bytesize
        branch = branches.find { |value| input.byteslice(cursor, value.bytesize) == value }
        if branch
          finish = cursor + branch.bytesize + suffix.bytesize
          if input.byteslice(cursor, finish - cursor) == branch + suffix
            captures = Array.new(number)
            captures[number - 1] = [cursor, cursor + branch.bytesize]
            return [cursor, finish, captures]
          end
        end
        cursor += 1
      end
      nil
    end

    def hfa_capture_component(node)
      if node.is_a?(AST::Assertion) && %i[positive positive_lookahead positive_lookbehind
                                          negative negative_lookahead negative_lookbehind].include?(node.kind)
        return [:guard, nil, nil]
      end
      return [:literal, node.value, nil] if node.is_a?(AST::Literal)

      if node.is_a?(AST::Quantifier) && node.kind == :"?" && node.expression.is_a?(AST::Group) &&
         node.expression.capture
        value = literal_ast_value(node.expression.body)
        return [:optional_literal, value, node.expression.number] if value
      end
      if node.is_a?(AST::Quantifier) && node.kind == :+ && node.mode == :greedy &&
         node.expression.is_a?(AST::Group) && node.expression.capture
        value = literal_ast_value(node.expression.body)
        return [:repeated_literal, value, node.expression.number] if value
      end
      return unless node.is_a?(AST::Group)

      number = node.capture ? node.number : nil
      value = literal_ast_value(node.body)
      return [:literal, value, number] if value

      body = node.body
      body = body.parts.first if body.is_a?(AST::Sequence) && body.parts.one?
      if node.capture && body.is_a?(AST::Quantifier) && body.kind == :* &&
         body.mode == :greedy
        value = literal_ast_value(body.expression)
        return [:optional_repeated_literal, value, number] if value
      end

      if node.capture && body.is_a?(AST::Quantifier) && body.kind == :+ &&
         body.mode == :greedy
        value = literal_ast_value(body.expression)
        return [:repeated_group_literal, value, number] if value
      end

      if node.capture && node.body.is_a?(AST::Alternation)
        branches = node.body.branches.map { |branch| literal_ast_value(branch) }
        return [:alternation_literal, branches.freeze, number] if branches.all?
      end

      return unless body.is_a?(AST::Quantifier) && body.kind == :+ && body.mode == :greedy

      table = hfa_capture_class_table(body.expression)
      table && [:class_run, table, number]
    end

    def hfa_capture_class_table(node)
      return ClassPredicates.compiled(node.value).ascii_table if node.is_a?(AST::CharacterClass)
      return if node.is_a?(AST::Any)

      if node.is_a?(AST::Escape)
        return HFA_ASCII_ESCAPE_TABLES[node.kind] if HFA_ASCII_ESCAPE_TABLES.key?(node.kind)

        return HFA_ASCII_ESCAPE_TABLES[node.kind] = 256.times.map do |byte|
          CharacterPredicates.escape_matches?(node.kind, byte.chr(Encoding::ASCII_8BIT))
        end.freeze
      end
      return unless node.is_a?(AST::Property)
      return unless UnicodeProperties::SUPPORTED.include?(node.name.sub("Is", "").sub("^", ""))

      cache_key = [node.name, node.negated]
      return HFA_ASCII_PROPERTY_TABLES[cache_key] if HFA_ASCII_PROPERTY_TABLES.key?(cache_key)

      HFA_ASCII_PROPERTY_TABLES[cache_key] = 256.times.map do |byte|
        matched = UnicodeProperties.matches?(node.name, byte.chr(Encoding::ASCII_8BIT))
        node.negated ? !matched : matched
      end.freeze
    end

    def hfa_capture_names
      @hfa_capture_names ||= CaptureNameCollector.indices(@ast)
    end

    def hfa_result_names
      @hfa_result_names ||= hfa_capture_names.transform_values(&:last).freeze
    end

    def hfa_static_capture_names
      return @hfa_static_capture_names if defined?(@hfa_static_capture_names)

      names = hfa_capture_names
      @hfa_static_capture_names = if names.values.all?(&:one?)
                                    names.transform_values(&:first).freeze
                                  else
                                    false
                                  end
    end

    def hfa_simple_capture_offsets(input, start, finish)
      layout = hfa_simple_capture_layout
      return unless layout

      cursor = start
      offsets = Array.new(hfa_simple_capture_count)
      layout.each do |kind, value, number|
        capture_start = nil
        case kind
        when :guard
          next
        when :literal
          return unless input.byteslice(cursor, value.bytesize) == value

          finish_position = cursor + value.bytesize
          captured = true
        when :optional_literal
          if input.byteslice(cursor, value.bytesize) == value
            finish_position = cursor + value.bytesize
            captured = true
          else
            finish_position = cursor
            captured = false
          end
        when :repeated_literal
          first = cursor
          cursor += value.bytesize while input.byteslice(cursor, value.bytesize) == value
          return if cursor == first

          finish_position = cursor
          captured = true
          capture_start = cursor - value.bytesize
        when :repeated_group_literal
          first = cursor
          cursor += value.bytesize while input.byteslice(cursor, value.bytesize) == value
          return if cursor == first

          finish_position = cursor
          captured = true
          capture_start = first
        when :optional_repeated_literal
          capture_start = cursor
          cursor += value.bytesize while input.byteslice(cursor, value.bytesize) == value
          finish_position = cursor
          captured = true
        when :alternation_literal
          branch = value.select { |candidate| input.byteslice(cursor, candidate.bytesize) == candidate }
                        .max_by(&:bytesize)
          return unless branch

          finish_position = cursor + branch.bytesize
          captured = true
        else
          finish_position = cursor
          finish_position += 1 while finish_position < finish && value[input.getbyte(finish_position)]
          return if finish_position == cursor

          captured = true
        end

        offsets[number - 1] = [capture_start || cursor, finish_position] if number && captured
        cursor = finish_position
      end
      return unless cursor == finish

      offsets
    end

    def literal_ast_value(node)
      return node.value if node.is_a?(AST::Literal)
      return unless node.is_a?(AST::Sequence)

      node.parts.map { |part| literal_ast_value(part) }.then { |values| values.all? ? values.join : nil }
    end

    def hfa_each_result(input, &block)
      return enum_for(__method__, input) unless block

      ascii_input = input.ascii_only?
      return true if hfa_always_fails?

      if hfa_empty_absence_result_safe?
        block.call([input.bytesize, input.bytesize, []])
        return true
      end
      if ascii_input && (spec = hfa_lookahead_literal_backreference_spec)
        position = 0
        while (result = hfa_lookahead_literal_backreference_match_result(input, position, spec))
          block.call(result)
          position = result[1]
        end
        return true
      end
      if hfa_literal_absence_result_safe?
        validate_encoding!(input, ascii_input: ascii_input) unless ascii_input
        position = 0
        while position <= input.bytesize
          result = hfa_literal_absence_match_result(input, position, byte_mode: !ascii_input)
          block.call(result)
          position = [result[1], position + 1].max
        end
        return true
      end
      return true if ascii_input && hfa_unicode_repeated_literal_result_safe?

      if !ascii_input && hfa_unicode_repeated_literal_result_safe?
        position = 0
        while (result = hfa_unicode_repeated_literal_match_result(input, position))
          block.call(result)
          position = result[1]
        end
        return true
      end
      if !ascii_input && input.encoding != Encoding::UTF_8 && hfa_unicode_property_result_safe?
        position = 0
        while (result = hfa_unicode_property_match_result(input, position))
          block.call(result)
          position = result[1]
        end
        return true
      end
      if (literal = hfa_scoped_unicode_ignorecase_literal_value)
        unless hfa_unicode_simple_casefold_each_result(input, literal) { |result| block.call(result) }
          position = 0
          while (result = hfa_unicode_ignorecase_literal_match_result(input, input.byteslice(0, position).to_s.length, literal))
            block.call(result)
            position = result[1]
          end
        end
        return true
      end
      if hfa_unicode_ignorecase_literal_result_safe? &&
         (literal = literal_ast_value(@ast)) && hfa_unicode_simple_casefold_each_result(input, literal) do |result|
                                                  block.call(result)
                                                end
        return true
      end

      if hfa_unicode_ignorecase_literal_result_safe?
        position = 0
        while (result = hfa_unicode_ignorecase_literal_match_result(input, input.byteslice(0, position).to_s.length))
          block.call(result)
          position = result[1]
        end
        return true
      end
      if ascii_input && hfa_match_reset_literal_result_safe?
        position = 0
        while (result = hfa_match_reset_literal_match_result(input, position))
          block.call(result)
          position = result[1]
        end
        return true
      end
      if ascii_input && hfa_class_run_positive_lookahead_result_safe?
        position = 0
        while (result = hfa_class_run_positive_lookahead_match_result(input, position))
          block.call(result)
          position = result[1]
        end
        return true
      end
      if hfa_variable_subexpression_capture_spec
        position = 0
        while (result = hfa_variable_subexpression_capture_match_result(input, position))
          block.call(result)
          position = result[1]
        end
        return true
      end
      if ascii_input && hfa_variable_capture_alternation_spec
        position = 0
        while (result = hfa_variable_capture_alternation_match_result(input, position))
          block.call(result)
          position = result[1]
        end
        return true
      end
      if ascii_input && hfa_atomic_literal_alternation_spec
        hfa_atomic_literal_alternation_each_result(input, &block)
        return true
      end
      if ascii_input && hfa_scoped_casefold_backref_spec
        position = 0
        while (result = hfa_scoped_casefold_backref_match_result(input, position))
          block.call(result)
          position = result[1]
        end
        return true
      end
      if ascii_input && hfa_variable_any_backref_spec
        position = 0
        while position <= input.bytesize
          result = hfa_variable_any_backref_match_result(input, position)
          block.call(result)
          position = [result[1], position + 1].max
        end
        return true
      end
      if ascii_input && hfa_lookahead_alternation_backreference_spec
        position = 0
        while (result = hfa_lookahead_alternation_backreference_match_result(input, position))
          block.call(result)
          position = result[1]
        end
        return true
      end
      if !ascii_input && input.encoding == Encoding::UTF_8 && hfa_unicode_repeated_literal_capture_result_safe?
        validate_encoding!(input, ascii_input: ascii_input)
        literal = @ast.parts.first.body.parts.first.expression.value
        position = 0
        while (start = input.byteindex(literal, position))
          finish = start + literal.bytesize
          finish += literal.bytesize while input.byteslice(finish, literal.bytesize) == literal
          block.call([start, finish, [[start, finish]]])
          position = finish
        end
        return true
      end

      if !hfa_program && hfa_leading_literal_assertion_result_safe?
        position = 0
        while (result = hfa_leading_literal_assertion_match_result(input, position))
          block.call(result)
          position = [result[1], position + 1].max
        end
        return true
      end

      if hfa_positive_lookbehind_result_safe?
        position = 0
        while (result = hfa_positive_lookbehind_literal_match_result(input, position))
          block.call(result)
          position = result[1]
        end
        return true
      end
      if hfa_casefold_class_lookbehind_parts
        position = 0
        while (result = hfa_casefold_class_lookbehind_match_result(input, position))
          block.call(result)
          position = result[1]
        end
        return true
      end
      if hfa_class_lookbehind_parts
        position = 0
        while (result = hfa_class_lookbehind_match_result(input, position))
          block.call(result)
          position = result[1]
        end
        return true
      end
      return false if hfa_capture_count.positive? && hfa_top_level_capture_plan && hfa_capture_offset_strategy == false

      program = hfa_program
      return false unless program

      strategy = hfa_capture_offset_strategy
      if %i[simple nested_literal nested_repeated adjacent_nested_repeated repeated_class subexpression].include?(strategy)
        program.each_match_result(input, 0) do |result|
          block.call(hfa_tagged_capture_result(input, result, strategy))
        end
      else
        program.each_match_result(input, 0) do |result|
          captures = (hfa_top_level_capture_offsets(input, result[0], result[1]) if hfa_top_level_capture_plan) ||
                     hfa_generic_capture_offsets(input, result[0], result[1])
          block.call([result[0], result[1], captures || result[2]])
        end
      end
      true
    end

    def hfa_delimited_negated_class_result_spec
      return @hfa_delimited_negated_class_result_spec if defined?(@hfa_delimited_negated_class_result_spec)

      parts = @ast.is_a?(AST::Sequence) ? @ast.parts : []
      prefix = parts.first
      suffix = parts.last
      middle = parts[1...-1]
      valid_literals = prefix.is_a?(AST::Literal) && suffix.is_a?(AST::Literal) &&
                       prefix.value.bytesize == 1 && suffix.value.bytesize == 1
      @hfa_delimited_negated_class_result_spec = if valid_literals &&
                                                    (minimum = hfa_negated_class_run_minimum(middle, suffix.value))
                                                   [prefix.value, suffix.value, minimum].freeze
                                                 else
                                                   false
                                                 end
    end

    def hfa_negated_class_run_minimum(parts, delimiter)
      return 0 if parts.one? && hfa_negated_class_quantifier?(parts.first, delimiter)
      return 1 if parts.length == 2 && parts.first.is_a?(AST::CharacterClass) &&
                  parts.first.value == "^#{delimiter}" &&
                  hfa_negated_class_quantifier?(parts.last, delimiter)

      nil
    end

    def hfa_negated_class_quantifier?(node, delimiter)
      node.is_a?(AST::Quantifier) && node.kind == :* && node.expression.is_a?(AST::CharacterClass) &&
        node.expression.value == "^#{delimiter}"
    end

    def hfa_positive_lookbehind_result_safe?
      return false unless @ast.is_a?(AST::Sequence) && @ast.parts.length >= 2

      assertion = @ast.parts[0]
      body = @ast.parts[1..]
      assertion.is_a?(AST::Assertion) && assertion.kind == :positive_lookbehind &&
        assertion.body.is_a?(AST::Sequence) && assertion.body.parts.all? { |part| part.is_a?(AST::Literal) } &&
        body.all? { |part| part.is_a?(AST::Literal) }
    end

    def hfa_negative_lookbehind_result_safe?
      return false unless @ast.is_a?(AST::Sequence) && @ast.parts.length >= 2

      assertion = @ast.parts[0]
      body = @ast.parts[1..]
      assertion.is_a?(AST::Assertion) && assertion.kind == :negative_lookbehind &&
        assertion.body.is_a?(AST::Sequence) && assertion.body.parts.all? { |part| part.is_a?(AST::Literal) } &&
        body.all? { |part| part.is_a?(AST::Literal) }
    end

    def hfa_conditional_result_safe?
      return false unless @ast.is_a?(AST::Sequence) && @ast.parts.length == 2

      optional, conditional = @ast.parts
      return false unless optional.is_a?(AST::Quantifier) && optional.kind == :"?" && optional.minimum.zero?
      return false unless optional.expression.is_a?(AST::Group) && conditional.is_a?(AST::Conditional)
      return false unless conditional.yes_branch.is_a?(AST::Sequence) &&
                          conditional.no_branch.is_a?(AST::Sequence)
      return false unless conditional.yes_branch.parts.all? { |part| part.is_a?(AST::Literal) } &&
                          conditional.no_branch.parts.all? { |part| part.is_a?(AST::Literal) }

      identifier = Array(conditional.condition).first
      matches_group = optional.expression.number == identifier.to_i ||
                      optional.expression.name.to_s == identifier.to_s
      matches_group && hfa_program
    end

    def hfa_subexpression_result_safe?
      return false unless @ast.is_a?(AST::Sequence) && @ast.parts.length == 2

      group, call = @ast.parts
      return false unless group.is_a?(AST::Group) && group.capture && call.is_a?(AST::SubexpressionCall)
      return false unless group.name && call.identifier.to_s == group.name.to_s

      literal_ast_value(group.body) && hfa_program
    end

    def hfa_nested_literal_capture_result_safe?
      return @hfa_nested_literal_capture_safe if defined?(@hfa_nested_literal_capture_safe)

      root = if @ast.is_a?(AST::Sequence) && @ast.parts.one?
               @ast.parts.first
             else
               @ast
             end
      return @hfa_nested_literal_capture_safe = false unless root.is_a?(AST::Group) && root.capture
      return @hfa_nested_literal_capture_safe = false if casefold?

      captures = []
      value = hfa_nested_literal_value(root, captures)
      @hfa_nested_literal_capture_safe = value && captures.length > 1 && hfa_program
    end

    def hfa_nested_repeated_capture_result_safe?
      return @hfa_nested_repeated_capture_safe if defined?(@hfa_nested_repeated_capture_safe)

      @hfa_nested_repeated_capture_safe = hfa_nested_repeated_capture_spec && hfa_program
    end

    def hfa_nested_repeated_capture_offsets(input, start, finish)
      return unless hfa_nested_repeated_capture_result_safe?

      _, suffix, unit, = hfa_nested_repeated_capture_spec
      repeat_finish = finish - suffix.bytesize
      return unless suffix.empty? || input.byteslice(repeat_finish, suffix.bytesize) == suffix

      span = hfa_repeated_match_span(unit, input, start, repeat_finish)
      return unless span && span.first == repeat_finish - start

      last_start = repeat_finish - span.last
      [[start, repeat_finish], [last_start, repeat_finish]]
    end

    def hfa_nested_repeated_capture_spec
      return @hfa_nested_repeated_capture_spec if defined?(@hfa_nested_repeated_capture_spec)

      root, suffix = hfa_nested_repeated_capture_parts
      body = root.body if root.is_a?(AST::Group) && root.capture
      body = body.parts.first if body.is_a?(AST::Sequence) && body.parts.one?
      inner = body.expression if body.is_a?(AST::Quantifier) && body.kind == :+ && body.mode == :greedy
      unit = inner.body if inner.is_a?(AST::Group) && inner.capture
      value = hfa_repeated_unit_value(unit) if unit
      @hfa_nested_repeated_capture_spec = if root && inner && value
                                            [root, suffix, unit, value].freeze
                                          else
                                            false
                                          end
    end

    def hfa_nested_repeated_capture_parts
      return @hfa_nested_repeated_capture_parts if defined?(@hfa_nested_repeated_capture_parts)

      parts = @ast.is_a?(AST::Sequence) ? @ast.parts : [@ast]
      return @hfa_nested_repeated_capture_parts = [parts.first, ""].freeze if parts.length == 1 && parts.first.is_a?(AST::Group)
      return @hfa_nested_repeated_capture_parts = [parts.first, parts.last.value].freeze if parts.length == 2 &&
                                                                                            parts.first.is_a?(AST::Group) && parts.last.is_a?(AST::Literal)

      @hfa_nested_repeated_capture_parts = [nil, nil].freeze
    end

    def hfa_adjacent_nested_repeated_capture_result_safe?
      return @hfa_adjacent_nested_repeated_capture_safe if defined?(@hfa_adjacent_nested_repeated_capture_safe)

      @hfa_adjacent_nested_repeated_capture_safe = hfa_adjacent_nested_repeated_capture_spec && hfa_program
    end

    def hfa_adjacent_nested_repeated_capture_groups
      return @hfa_adjacent_nested_repeated_capture_groups if defined?(@hfa_adjacent_nested_repeated_capture_groups)

      parts = @ast.is_a?(AST::Sequence) ? @ast.parts : []
      return @hfa_adjacent_nested_repeated_capture_groups = false if parts.length < 2
      return @hfa_adjacent_nested_repeated_capture_groups = false unless parts.all? do |part|
        part.is_a?(AST::Group) && part.capture && hfa_repeated_group_node?(part)
      end

      @hfa_adjacent_nested_repeated_capture_groups = parts
    end

    def hfa_adjacent_nested_repeated_capture_offsets(input, start, finish)
      groups, units, _, capture_count = hfa_adjacent_nested_repeated_capture_spec
      return unless groups

      boundaries = hfa_adjacent_repeated_boundaries(input, start, finish, units)
      return unless boundaries

      offsets = Array.new(capture_count)
      groups.each_with_index do |group, index|
        group_start = boundaries[index]
        group_finish = boundaries[index + 1]
        body = group.body.parts.first
        inner = body.expression
        span = hfa_repeated_match_span(inner.body, input, group_start, group_finish)
        return unless span && span.first == group_finish - group_start

        offsets[group.number - 1] = [group_start, group_finish]
        offsets[inner.number - 1] = [group_finish - span.last, group_finish]
      end
      offsets
    end

    def hfa_adjacent_nested_repeated_capture_spec
      return @hfa_adjacent_nested_repeated_capture_spec if defined?(@hfa_adjacent_nested_repeated_capture_spec)

      groups = hfa_adjacent_nested_repeated_capture_groups
      @hfa_adjacent_nested_repeated_capture_spec = if groups
                                                     units = groups.map { |group| hfa_repeated_group_node_unit(group) }.freeze
                                                     numbers = groups.flat_map do |group|
                                                       [group.number, group.body.parts.first.expression.number]
                                                     end.freeze
                                                     [groups, units, numbers, numbers.max].freeze
                                                   else
                                                     false
                                                   end
    end

    def hfa_repeated_group_node_unit(group)
      body = group.body.parts.first
      hfa_repeated_unit_value(body.expression.body)
    end

    def hfa_adjacent_repeated_boundaries(input, start, finish, units)
      search = lambda do |index, cursor|
        return [cursor] if index == units.length

        unit = units[index]
        max = cursor
        max += unit.bytesize while input.byteslice(max, unit.bytesize) == unit
        max_units = (max - cursor) / unit.bytesize
        max_units.downto(1) do |count|
          boundary = cursor + count * unit.bytesize
          next if index == units.length - 1 && boundary != finish

          suffix = search.call(index + 1, boundary)
          return [boundary, *suffix] if suffix
        end
        nil
      end

      result = search.call(0, start)
      result && result.last == finish ? [start, *result] : nil
    end

    def hfa_repeated_class_capture_parts
      return @hfa_repeated_class_capture_parts if defined?(@hfa_repeated_class_capture_parts)

      return @hfa_repeated_class_capture_parts = false unless @ast.is_a?(AST::Sequence) && @ast.parts.length >= 3

      repeated = @ast.parts[0]
      suffix = @ast.parts[1..]
      return @hfa_repeated_class_capture_parts = false unless repeated.is_a?(AST::Group) && repeated.capture && suffix.length.even?

      pairs = suffix.each_slice(2).to_a
      return @hfa_repeated_class_capture_parts = false unless pairs.all? do |separator, class_group|
        separator.is_a?(AST::Literal) && class_group.is_a?(AST::Group) && class_group.capture
      end

      @hfa_repeated_class_capture_parts = [repeated, pairs].freeze
    end

    def hfa_repeated_class_capture_result_safe?
      return @hfa_repeated_class_capture_safe if defined?(@hfa_repeated_class_capture_safe)

      @hfa_repeated_class_capture_safe = hfa_repeated_class_capture_spec && hfa_program
    end

    def hfa_repeated_group_node?(group)
      body = group.body
      body = body.parts.first if body.is_a?(AST::Sequence) && body.parts.one?
      body.is_a?(AST::Quantifier) && body.kind == :+ && body.mode == :greedy &&
        body.expression.is_a?(AST::Group) && body.expression.capture &&
        hfa_repeated_unit_value(body.expression.body)
    end

    def hfa_repeated_class_capture_offsets(input, start, finish)
      return unless hfa_repeated_class_capture_result_safe?

      repeated, pairs, _, class_specs, capture_count = hfa_repeated_class_capture_spec
      separator_position = input.index(pairs.first.first.value, start)
      return unless separator_position && separator_position < finish

      repeated_body = repeated.body.parts.first
      span = hfa_repeated_match_span(repeated_body.expression.body, input, start, separator_position)
      return unless span && span.first == separator_position - start

      offsets = Array.new(capture_count)
      offsets[repeated.number - 1] = [start, separator_position]
      offsets[repeated.body.parts.first.expression.number - 1] =
        [separator_position - span.last, separator_position]
      cursor = separator_position
      pairs.each_with_index do |(separator, class_group), index|
        return unless input.byteslice(cursor, separator.value.bytesize) == separator.value

        class_start = cursor + separator.value.bytesize
        class_finish = if (next_pair = pairs[index + 1])
                         input.index(next_pair.first.value, class_start)
                       else
                         finish
                       end
        return unless class_finish && class_finish > class_start

        table, inner_number = class_specs[index]
        cursor = class_start
        cursor += 1 while cursor < class_finish && table[input.getbyte(cursor)]
        return unless cursor == class_finish

        offsets[class_group.number - 1] = [class_start, class_finish]
        offsets[inner_number - 1] = [class_finish - 1, class_finish] if inner_number
      end
      return unless cursor == finish

      offsets
    end

    def hfa_repeated_class_capture_spec
      return @hfa_repeated_class_capture_spec if defined?(@hfa_repeated_class_capture_spec)

      parts = hfa_repeated_class_capture_parts
      @hfa_repeated_class_capture_spec = if parts
                                           repeated, pairs = parts
                                           if hfa_repeated_group_node?(repeated)
                                             class_specs = pairs.map { |_separator, group| hfa_class_capture_spec(group) }
                                             if class_specs.all?
                                               numbers = [repeated.number, repeated.body.parts.first.expression.number] +
                                                         class_specs.flat_map { |_table, number| [number] }.compact
                                               [repeated, pairs, numbers.freeze, class_specs.freeze, numbers.max].freeze
                                             end
                                           end
                                         end || false
    end

    def hfa_class_capture_spec(group)
      body = group.body
      body = body.parts.first if body.is_a?(AST::Sequence) && body.parts.one?
      return unless body.is_a?(AST::Quantifier) && body.kind == :+ && body.mode == :greedy

      if body.expression.is_a?(AST::Group) && body.expression.capture
        inner = body.expression.body
        inner = inner.parts.first if inner.is_a?(AST::Sequence) && inner.parts.one?
        table = hfa_capture_class_table(inner)
        return [table, body.expression.number] if table
      end

      table = hfa_capture_class_table(body.expression)
      table && [table, nil]
    end

    def hfa_repeated_unit_value(node)
      return literal_ast_value(node) unless node.is_a?(AST::Alternation)

      values = node.branches.map { |branch| literal_ast_value(branch) }
      values.all? && values.each_cons(2).all? { |left, right| left.bytesize >= right.bytesize } ? values.first : nil
    end

    def hfa_repeated_match_span(node, input, start, finish)
      cursor = start
      last_length = nil
      while cursor < finish
        length = hfa_nested_literal_match_length(node, input, cursor)
        return unless length&.positive? && cursor + length <= finish

        cursor += length
        last_length = length
      end
      [cursor - start, last_length] if cursor == finish && last_length
    end

    def repeated_alternation_ast?
      return false unless @ast.is_a?(AST::Sequence) && @ast.parts.length == 2

      repeat, suffix = @ast.parts
      body = repeat.expression if repeat.is_a?(AST::Quantifier)
      body = body.body if body.is_a?(AST::Group)
      repeat.is_a?(AST::Quantifier) && repeat.kind == :+ && repeat.mode == :greedy &&
        body.is_a?(AST::Alternation) && suffix.is_a?(AST::Literal)
    end

    def fixed_class_run_literal_ast?
      return false unless @ast.is_a?(AST::Sequence) && @ast.parts.length == 3

      prefix, run, suffix = @ast.parts
      prefix.is_a?(AST::Literal) && suffix.is_a?(AST::Literal) &&
        run.is_a?(AST::Quantifier) && run.kind == :bounded && run.minimum == run.maximum &&
        run.minimum.positive? && run.expression.is_a?(AST::CharacterClass)
    end

    def dot_literal_ast?
      return false unless @ast.is_a?(AST::Sequence) && @ast.parts.length == 3

      prefix, wildcard, suffix = @ast.parts
      prefix.is_a?(AST::Literal) && prefix.value.bytesize == 1 && wildcard.is_a?(AST::Any) &&
        suffix.is_a?(AST::Literal) && suffix.value.bytesize == 1
    end

    def repeat_literal_ast?
      return false unless @ast.is_a?(AST::Sequence) && @ast.parts.length == 2

      repeat, suffix = @ast.parts
      repeat.is_a?(AST::Quantifier) && repeat.kind == :+ && repeat.mode == :greedy &&
        repeat.expression.is_a?(AST::Literal) && repeat.expression.value.bytesize == 1 &&
        suffix.is_a?(AST::Literal)
    end

    def ascii_repeated_literal_run_ast?
      return false if casefold?
      return false unless @ast.is_a?(AST::Sequence) && @ast.parts.one?

      repeat = @ast.parts.first
      repeat.is_a?(AST::Quantifier) && repeat.kind == :+ && repeat.mode == :greedy &&
        repeat.expression.is_a?(AST::Literal) && repeat.expression.value.ascii_only? &&
        repeat.expression.value.bytesize.positive?
    end

    def class_run_chain_ast?
      return false unless @ast.is_a?(AST::Sequence) && @ast.parts.length == 3

      left, separator, right = @ast.parts
      separator.is_a?(AST::Literal) && class_run_result_node?(left) && class_run_result_node?(right)
    end

    def adjacent_class_run_ast?
      return false unless @ast.is_a?(AST::Sequence) && @ast.parts.length == 2

      left, right = @ast.parts
      class_run_result_node?(left) && class_run_result_node?(right)
    end

    def class_run_triple_ast?
      return false unless @ast.is_a?(AST::Sequence) && @ast.parts.length == 3

      @ast.parts.all? { |part| class_run_result_node?(part) }
    end

    def hfa_iterator_node?(node)
      return true if node.is_a?(AST::Literal) || node.is_a?(AST::CharacterClass) || node.is_a?(AST::Any)
      return true if node.is_a?(AST::Quantifier) && node.mode == :greedy && node.expression.is_a?(AST::Literal)
      return true if class_run_result_node?(node)
      return node.parts.all? { |part| part.is_a?(AST::Literal) } if node.is_a?(AST::Sequence)

      false
    end

    def validate_pattern_type!(pattern)
      return if pattern.is_a?(String)

      raise TypeError, "no implicit conversion of #{pattern.class} into String"
    end

    def validate_pattern_encoding!(pattern)
      return if pattern.valid_encoding?

      raise RegexpError, "invalid byte sequence in #{pattern.encoding}"
    end

    def validate_pattern_syntax!(pattern, options)
      tokens = Lexer.new(pattern, options).tokens
      binary_pattern = pattern.encoding == Encoding::ASCII_8BIT || options.include?("noencoding")
      raise RegexpError, "Unicode properties require a text encoding" if binary_pattern && tokens.any? { |token| token.type == :property }

      tokens
    end
  end
end

require_relative "onibi/hybrid_automata"
require_relative "onibi/hybrid_automata/cfg"
require_relative "onibi/hybrid_automata/layout_facts"
require_relative "onibi/hybrid_automata/position_builder"
require_relative "onibi/hybrid_automata/optimization"
