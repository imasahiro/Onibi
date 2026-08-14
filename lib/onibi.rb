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
require_relative "onibi/candidate_source"
require_relative "onibi/swar"
require_relative "onibi/codegen"
require_relative "onibi/search_plan"
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

    class TimeoutError < RegexpError
    end

    def self.compile(pattern, options = nil, timeout: nil) = new(pattern, options, timeout: timeout)

    def initialize(pattern, options = nil, timeout: nil)
      pattern, options, timeout = normalize_constructor_pattern(pattern, options, timeout)
      pattern, normalized_options = prepare_constructor_pattern(pattern, options)
      @timeout = RegexpTimeout.normalize_timeout(timeout)
      tokens = validate_pattern_syntax!(pattern, normalized_options)
      @ast = Codegen::Optimization.prepare(Parser.new(tokens).parse, normalized_options)
      @analysis = Codegen::Analyzer.new(normalized_options, pattern.encoding,
                                        boundary_analysis: false).analyze(@ast)
      literal = if @ast.is_a?(AST::Literal) || @ast.is_a?(AST::Sequence)
                  literal_ast_value(@ast)
                end
      @hfa_exact_literal_fast = literal if literal&.ascii_only? && literal.bytesize.positive? &&
                                           !@options.include?("ignorecase")
      @hfa_ignorecase_literal_fast = literal if literal&.ascii_only? && literal.bytesize.positive? &&
                                                @options.include?("ignorecase")
      @hfa_unicode_exact_literal_fast = literal if literal && !literal.ascii_only? &&
                                                   literal.bytesize.positive? &&
                                                   !@options.include?("ignorecase")
      @hfa_unicode_ignorecase_literal_fast = literal if literal && !literal.ascii_only? &&
                                                        literal.bytesize.positive? &&
                                                        @options.include?("ignorecase")
      property_node = if @ast.is_a?(AST::Sequence) && @ast.parts.one?
                        node = @ast.parts.first
                        node.expression if node.is_a?(AST::Quantifier) && node.kind == :+ &&
                                           node.mode == :greedy && node.expression.is_a?(AST::Property)
                      end
      @hfa_unicode_property_run_fast = property_node if property_node &&
                                                        property_node.name.sub("Is", "").sub("^", "") == "Hiragana" &&
                                                        !@options.include?("ignorecase")
      @hfa_ascii_unicode_run_fast = property_node if property_node && !@options.include?("ignorecase") &&
                                                     hfa_capture_class_table(property_node)
      chain_candidate = !@options.include?("ignorecase") && @ast.is_a?(AST::Sequence) &&
                        @ast.parts.length == 3 && @ast.parts.all? do |part|
                          part.is_a?(AST::Quantifier) && part.kind == :+ && part.mode == :greedy &&
                            (part.expression.is_a?(AST::CharacterClass) || part.expression.is_a?(AST::Escape))
                        end
      chain_tables = hfa_ascii_run_chain_tables if chain_candidate
      @hfa_ascii_run_chain_fast = chain_tables if chain_tables
      anchored_candidate = if !@options.include?("ignorecase") && @ast.is_a?(AST::Sequence) &&
                             @ast.parts.length == 3
                            start, run, finish = @ast.parts
                            start.is_a?(AST::Anchor) && start.kind == :anchor_absolute_start &&
                              run.is_a?(AST::Quantifier) && run.kind == :+ && run.mode == :greedy &&
                              run.expression.is_a?(AST::CharacterClass) &&
                              finish.is_a?(AST::Anchor) && finish.kind == :anchor_absolute_end
                          end
      @hfa_anchored_class_run_fast = hfa_anchored_class_run_table if anchored_candidate
      alternation_values = if !@options.include?("ignorecase") && @ast.is_a?(AST::Alternation)
                             @ast.branches.map { |branch| literal_ast_value(branch) }
                           end
      @hfa_literal_alternation_fast = alternation_values.freeze if alternation_values && alternation_values.length > 1 &&
                                                                  alternation_values.all? { |value| value&.ascii_only? && value.bytesize.positive? }
      dot_candidate = @ast.is_a?(AST::Sequence) && @ast.parts.length == 3 &&
                      @ast.parts[0].is_a?(AST::Literal) && @ast.parts[1].is_a?(AST::Any) &&
                      @ast.parts[2].is_a?(AST::Literal) && @ast.parts[0].value.ascii_only? &&
                      @ast.parts[2].value.ascii_only? && @ast.parts[0].value.bytesize == 1 &&
                      @ast.parts[2].value.bytesize == 1 && !@options.include?("ignorecase")
      @hfa_dot_literal_fast = hfa_dot_literal_parts if dot_candidate
      boundary_literal = hfa_word_boundary_literal_result_safe?
      @hfa_word_boundary_literal_fast = boundary_literal if boundary_literal.is_a?(String)
      assertion_parts = hfa_literal_assertion_result_safe? unless @options.include?("ignorecase")
      if assertion_parts.is_a?(Array) && assertion_parts[1] == :positive_lookbehind &&
         assertion_parts[0].ascii_only? && assertion_parts[2].ascii_only?
        @hfa_positive_lookbehind_literal_fast = [assertion_parts[2], assertion_parts[0]].freeze
      elsif assertion_parts.is_a?(Array) && assertion_parts[1] == :negative_lookbehind &&
            assertion_parts[0].ascii_only? && assertion_parts[2].ascii_only?
        @hfa_negative_lookbehind_literal_fast = [assertion_parts[0], assertion_parts[2]].freeze
      end
      match_reset_literal = hfa_match_reset_literal_combined_literal
      @hfa_match_reset_literal_fast = match_reset_literal if match_reset_literal
      lookahead_candidate = if !@options.include?("ignorecase") && @ast.is_a?(AST::Sequence) && @ast.parts.length == 2
                              run, assertion = @ast.parts
                              guard = assertion.body if assertion.is_a?(AST::Assertion)
                              guard_parts = guard.parts if guard.is_a?(AST::Sequence)
                              run.is_a?(AST::Quantifier) && run.kind == :+ && run.mode == :greedy &&
                                run.expression.is_a?(AST::CharacterClass) && assertion.is_a?(AST::Assertion) &&
                                assertion.kind == :positive &&
                                guard_parts&.length == 2 && guard_parts[0].is_a?(AST::Literal) &&
                                guard_parts[1].is_a?(AST::Quantifier) && guard_parts[1].kind == :+ &&
                                guard_parts[1].mode == :greedy && guard_parts[1].expression.is_a?(AST::CharacterClass)
                            end
      @hfa_class_run_positive_lookahead_fast = hfa_class_run_positive_lookahead_tables if lookahead_candidate
      @hfa_empty_absence_fast = true if @ast.is_a?(AST::Sequence) && @ast.parts.one? &&
                                         @ast.parts.first.is_a?(AST::Absence)
      conditional_parts = hfa_literal_conditional_parts
      @hfa_literal_conditional_fast = conditional_parts if conditional_parts.all?
      word_node = if @ast.is_a?(AST::Sequence) && @ast.parts.one?
                    node = @ast.parts.first
                    node.expression if node.is_a?(AST::Quantifier) && node.kind == :+ &&
                                       node.mode == :greedy && node.expression.is_a?(AST::CharacterClass) &&
                                       node.expression.value == "[:word:]"
                  end
      @hfa_unicode_word_class_run_fast = word_node if word_node && !@options.include?("ignorecase")
    end

    def match?(input, position = 0)
      raise TypeError, "no implicit conversion of #{input.class} into String" unless input.is_a?(String)

      validate_encoding!(input)
      if @hfa_exact_literal_fast
        literal = @hfa_exact_literal_fast
        start_position = position.is_a?(Integer) && position.zero? ? 0 : normalize_match_position(input, position)
        return !input.index(literal, start_position).nil?
      end
      return true if @hfa_empty_absence_fast
      if input.ascii_only? && @hfa_literal_alternation_fast
        normalized_position = position.is_a?(Integer) && position.zero? ? 0 : normalize_match_position(input, position)
        return @hfa_literal_alternation_fast.any? { |value| !input.index(value, normalized_position).nil? }
      end
      if input.ascii_only? && @hfa_literal_conditional_fast
        normalized_position = position.is_a?(Integer) && position.zero? ? 0 : normalize_match_position(input, position)
        return hfa_literal_conditional_match?(input, normalized_position)
      end
      if input.ascii_only? && @hfa_dot_literal_fast
        normalized_position = position.is_a?(Integer) && position.zero? ? 0 : normalize_match_position(input, position)
        return hfa_dot_literal_match?(input, normalized_position)
      end
      if input.ascii_only? && @hfa_word_boundary_literal_fast
        normalized_position = position.is_a?(Integer) && position.zero? ? 0 : normalize_match_position(input, position)
        return !hfa_word_boundary_literal_match_result(input, normalized_position).nil?
      end
      if input.ascii_only? && @hfa_positive_lookbehind_literal_fast
        normalized_position = position.is_a?(Integer) && position.zero? ? 0 : normalize_match_position(input, position)
        prefix, literal = @hfa_positive_lookbehind_literal_fast
        candidate = input.index(prefix + literal, [normalized_position - prefix.bytesize, 0].max)
        while candidate
          return true if candidate + prefix.bytesize >= normalized_position

          candidate = input.index(prefix + literal, candidate + 1)
        end
        return false
      end
      if input.ascii_only? && @hfa_negative_lookbehind_literal_fast
        normalized_position = position.is_a?(Integer) && position.zero? ? 0 : normalize_match_position(input, position)
        literal, guard = @hfa_negative_lookbehind_literal_fast
        candidate = input.index(literal, normalized_position)
        while candidate
          return true if candidate < guard.bytesize ||
                         input.byteslice(candidate - guard.bytesize, guard.bytesize) != guard

          candidate = input.index(literal, candidate + 1)
        end
        return false
      end
      if input.ascii_only? && @hfa_ascii_unicode_run_fast
        normalized_position = position.is_a?(Integer) && position.zero? ? 0 : normalize_match_position(input, position)
        return hfa_ascii_unicode_run_match?(input, normalized_position)
      end
      if input.ascii_only? && @hfa_ascii_run_chain_fast
        normalized_position = position.is_a?(Integer) && position.zero? ? 0 : normalize_match_position(input, position)
        return hfa_ascii_run_chain_match?(input, normalized_position)
      end
      if input.ascii_only? && @hfa_anchored_class_run_fast
        normalized_position = position.is_a?(Integer) && position.zero? ? 0 : normalize_match_position(input, position)
        return hfa_anchored_class_run_match?(input, normalized_position)
      end
      if input.ascii_only? && @hfa_ignorecase_literal_fast
        normalized_position = normalize_match_position(input, position)
        return hfa_ignorecase_literal_match?(input, normalized_position) if timeout_unconfigured?

        result = hfa_ignorecase_literal_match_result(input, normalized_position)
        return with_timeout { !result.nil? }
      end
      if !input.ascii_only? && @hfa_unicode_ignorecase_literal_fast
        normalized_position = normalize_match_position(input, position)
        return hfa_unicode_ignorecase_literal_match?(input, normalized_position) if timeout_unconfigured?

        result = hfa_unicode_ignorecase_literal_match_result(input, normalized_position)
        return with_timeout { !result.nil? }
      end
      if !input.ascii_only? && @hfa_unicode_exact_literal_fast
        literal = @hfa_unicode_exact_literal_fast
        start_position = position.is_a?(Integer) && position.zero? ? 0 : normalize_match_position(input, position)
        return !input.index(literal, start_position).nil?
      end
      if !input.ascii_only? && @hfa_unicode_property_run_fast
        normalized_position = position.is_a?(Integer) && position.zero? ? 0 : normalize_match_position(input, position)
        return hfa_unicode_property_run_match?(input, normalized_position)
      end
      if !input.ascii_only? && @hfa_unicode_word_class_run_fast
        normalized_position = position.is_a?(Integer) && position.zero? ? 0 : normalize_match_position(input, position)
        return hfa_unicode_word_class_run_match?(input, normalized_position)
      end
      if input.ascii_only? && hfa_ascii_unicode_run_result_safe?
        normalized_position = position.is_a?(Integer) && position.zero? ? 0 : normalize_match_position(input, position)
        return hfa_ascii_unicode_run_match?(input, normalized_position)
      end
      if input.ascii_only? && hfa_ascii_class_run_result_safe?
        normalized_position = position.is_a?(Integer) && position.zero? ? 0 : normalize_match_position(input, position)
        return hfa_ascii_class_run_match?(input, normalized_position)
      end
      if input.ascii_only? && hfa_ascii_run_chain_result_safe?
        normalized_position = position.is_a?(Integer) && position.zero? ? 0 : normalize_match_position(input, position)
        return hfa_ascii_run_chain_match?(input, normalized_position)
      end
      if input.ascii_only? && hfa_ascii_adjacent_run_result_safe?
        normalized_position = position.is_a?(Integer) && position.zero? ? 0 : normalize_match_position(input, position)
        return hfa_ascii_adjacent_run_match?(input, normalized_position)
      end
      if input.ascii_only? && (literal = hfa_atomic_literal_match_literal)
        normalized_position = position.is_a?(Integer) && position.zero? ? 0 : normalize_match_position(input, position)
        return !input.index(literal, normalized_position).nil?
      end
      if input.ascii_only? && (literal = hfa_subexpression_literal_match_literal)
        normalized_position = position.is_a?(Integer) && position.zero? ? 0 : normalize_match_position(input, position)
        return !input.index(literal, normalized_position).nil?
      end
      if input.ascii_only? && (parts = hfa_greedy_dot_star_literal_parts)
        normalized_position = position.is_a?(Integer) && position.zero? ? 0 : normalize_match_position(input, position)
        return hfa_greedy_dot_star_literal_match?(input, normalized_position, parts)
      end
      if input.ascii_only? && (parts = hfa_lazy_dot_star_literal_parts)
        normalized_position = position.is_a?(Integer) && position.zero? ? 0 : normalize_match_position(input, position)
        return hfa_greedy_dot_star_literal_match?(input, normalized_position, parts)
      end
      if input.ascii_only? && hfa_literal_conditional_result_safe?
        normalized_position = position.is_a?(Integer) && position.zero? ? 0 : normalize_match_position(input, position)
        return hfa_literal_conditional_match?(input, normalized_position)
      end
      if input.ascii_only? && hfa_repeated_class_backref_result_safe?
        normalized_position = position.is_a?(Integer) && position.zero? ? 0 : normalize_match_position(input, position)
        return hfa_repeated_class_backref_match?(input, normalized_position)
      end
      if input.ascii_only? && hfa_anchored_class_run_result_safe?
        normalized_position = position.is_a?(Integer) && position.zero? ? 0 : normalize_match_position(input, position)
        return hfa_anchored_class_run_match?(input, normalized_position)
      end
      if input.ascii_only? && hfa_literal_alternation_result_safe?
        normalized_position = position.is_a?(Integer) && position.zero? ? 0 : normalize_match_position(input, position)
        return hfa_literal_alternation_match?(input, normalized_position)
      end
      if input.ascii_only? && hfa_dot_literal_result_safe?
        normalized_position = position.is_a?(Integer) && position.zero? ? 0 : normalize_match_position(input, position)
        return hfa_dot_literal_match?(input, normalized_position)
      end
      if input.ascii_only? && hfa_word_boundary_literal_result_safe?
        normalized_position = position.is_a?(Integer) && position.zero? ? 0 : normalize_match_position(input, position)
        return !hfa_word_boundary_literal_match_result(input, normalized_position).nil?
      end
      if input.ascii_only? && hfa_literal_assertion_result_safe?
        normalized_position = position.is_a?(Integer) && position.zero? ? 0 : normalize_match_position(input, position)
        return !hfa_literal_assertion_match_result(input, normalized_position).nil?
      end
      if input.ascii_only? && hfa_possessive_literal_string_result_safe?
        normalized_position = position.is_a?(Integer) && position.zero? ? 0 : normalize_match_position(input, position)
        return !hfa_possessive_literal_string_match_result(input, normalized_position).nil?
      end
      if input.ascii_only? && hfa_captured_class_run_chain_result_safe?
        normalized_position = position.is_a?(Integer) && position.zero? ? 0 : normalize_match_position(input, position)
        return hfa_captured_class_run_chain_match?(input, normalized_position)
      end
      if input.ascii_only? && @hfa_match_reset_literal_fast
        normalized_position = position.is_a?(Integer) && position.zero? ? 0 : normalize_match_position(input, position)
        return !input.index(@hfa_match_reset_literal_fast, normalized_position).nil?
      end
      if input.ascii_only? && (literal = hfa_match_reset_literal_combined_literal)
        normalized_position = position.is_a?(Integer) && position.zero? ? 0 : normalize_match_position(input, position)
        return !input.index(literal, normalized_position).nil?
      end
      if input.ascii_only? && hfa_match_reset_literal_result_safe?
        normalized_position = position.is_a?(Integer) && position.zero? ? 0 : normalize_match_position(input, position)
        return hfa_match_reset_literal_match?(input, normalized_position)
      end
      if input.ascii_only? && @hfa_class_run_positive_lookahead_fast
        normalized_position = position.is_a?(Integer) && position.zero? ? 0 : normalize_match_position(input, position)
        return hfa_class_run_positive_lookahead_match?(input, normalized_position)
      end
      if input.ascii_only? && hfa_class_run_positive_lookahead_result_safe?
        normalized_position = position.is_a?(Integer) && position.zero? ? 0 : normalize_match_position(input, position)
        return hfa_class_run_positive_lookahead_match?(input, normalized_position)
      end
      if !input.ascii_only? && hfa_unicode_exact_literal_result_safe?
        literal = hfa_exact_literal_value
        start_position = position.is_a?(Integer) && position.zero? ? 0 : normalize_match_position(input, position)
        return !input.b.index(literal.b, start_position).nil?
      end
      if !input.ascii_only? && hfa_unicode_property_run_result_safe?
        normalized_position = position.is_a?(Integer) && position.zero? ? 0 : normalize_match_position(input, position)
        return hfa_unicode_property_run_match?(input, normalized_position)
      end
      if !input.ascii_only? && hfa_unicode_word_class_run_result_safe?
        normalized_position = position.is_a?(Integer) && position.zero? ? 0 : normalize_match_position(input, position)
        return hfa_unicode_word_class_run_match?(input, normalized_position)
      end
      if !input.ascii_only? && (literal = hfa_unicode_fixed_literal_capture_literal)
        normalized_position = position.is_a?(Integer) && position.zero? ? 0 : normalize_match_position(input, position)
        return !input.index(literal, normalized_position).nil?
      end
      if !input.ascii_only? && hfa_fixed_literal_capture_result_safe?
        normalized_position = position.is_a?(Integer) && position.zero? ? 0 : normalize_match_position(input, position)
        return hfa_fixed_literal_capture_match?(input, normalized_position)
      end
      if !input.ascii_only? && hfa_unicode_ignorecase_literal_result_safe?
        normalized_position = normalize_match_position(input, position)
        return hfa_unicode_ignorecase_literal_match?(input, normalized_position) if timeout_unconfigured?

        result = hfa_unicode_ignorecase_literal_match_result(input, normalized_position)
        return with_timeout { !result.nil? } unless timeout_unconfigured?
      end
      if !input.ascii_only? && hfa_unicode_repeated_literal_result_safe?
        normalized_position = position.is_a?(Integer) && position.zero? ? 0 : normalize_match_position(input, position)
        return !hfa_unicode_repeated_literal_match_result(input, normalized_position).nil?
      end
      if input.ascii_only? && hfa_ignorecase_literal_result_safe?
        normalized_position = normalize_match_position(input, position)
        return hfa_ignorecase_literal_match?(input, normalized_position) if timeout_unconfigured?

        result = hfa_ignorecase_literal_match_result(input, normalized_position)
        return with_timeout { !result.nil? }
      end
      if !input.ascii_only? && (hfa_unicode_match_result_safe? || hfa_unicode_literal_result_safe? ||
                                hfa_unicode_simple_capture_result_safe? ||
                                hfa_unicode_repeated_literal_result_safe?)
        hfa = hfa_program
        if hfa
          normalized_position = position.is_a?(Integer) && position.zero? ? 0 : normalize_match_position(input, position)
          if hfa_unicode_repeated_literal_result_safe?
            return !hfa_unicode_repeated_literal_match_result(input, normalized_position).nil?
          end
          return hfa.match?(input, normalized_position) if timeout_unconfigured?

          return with_timeout { hfa.match?(input, normalized_position) }
        end
      end

      hfa = hfa_program if input.ascii_only? && hfa_match_question_safe?
      if hfa
        normalized_position = position.is_a?(Integer) && position.zero? ? 0 : normalize_match_position(input, position)
        return hfa.match?(input, normalized_position) if timeout_unconfigured?

        return with_timeout { hfa.match?(input, normalized_position) }
      end

      codegen_match?(input, position)
    end

    def match(input, position = 0)
      raise TypeError, "no implicit conversion of #{input.class} into String" unless input.is_a?(String)

      validate_encoding!(input)
      if input.ascii_only? && hfa_exact_literal_result_safe?
        literal = hfa_exact_literal_value
        start_position = position.is_a?(Integer) && position.zero? ? 0 : normalize_match_position(input, position)
        start = input.index(literal, start_position)
        return hfa_match_data([start, start + literal.bytesize, []], input) if start
        return nil
      end
      if input.ascii_only? && hfa_word_boundary_literal_result_safe?
        normalized_position = position.is_a?(Integer) && position.zero? ? 0 : normalize_match_position(input, position)
        result = hfa_word_boundary_literal_match_result(input, normalized_position)
        return hfa_match_data(result, input) if result
        return nil
      end
      if input.ascii_only? && hfa_literal_assertion_result_safe?
        normalized_position = position.is_a?(Integer) && position.zero? ? 0 : normalize_match_position(input, position)
        result = hfa_literal_assertion_match_result(input, normalized_position)
        return hfa_match_data(result, input) if result
        return nil
      end
      if input.ascii_only? && hfa_possessive_literal_string_result_safe?
        normalized_position = position.is_a?(Integer) && position.zero? ? 0 : normalize_match_position(input, position)
        result = hfa_possessive_literal_string_match_result(input, normalized_position)
        return hfa_match_data(result, input) if result
        return nil
      end
      if !input.ascii_only? && hfa_unicode_exact_literal_result_safe?
        literal = hfa_exact_literal_value
        start_position = position.is_a?(Integer) && position.zero? ? 0 : normalize_match_position(input, position)
        start = input.b.index(literal.b, start_position)
        return hfa_match_data([start, start + literal.bytesize, []], input) if start
        return nil
      end
      if !input.ascii_only? && hfa_unicode_ignorecase_literal_result_safe?
        result = hfa_unicode_ignorecase_literal_match_result(input, position)
        return hfa_match_data(result, input) if result
        return nil
      end
      if input.ascii_only? && hfa_ignorecase_literal_result_safe?
        result = hfa_ignorecase_literal_match_result(input, position)
        return hfa_match_data(result, input) if result
        return nil
      end

      if !input.ascii_only? && (hfa_unicode_match_result_safe? || hfa_unicode_literal_result_safe? ||
                                hfa_unicode_simple_capture_result_safe? ||
                                hfa_unicode_repeated_literal_result_safe?)
        if hfa_unicode_repeated_literal_result_safe?
          result = hfa_unicode_repeated_literal_match_result(input, position)
          return hfa_match_data(result, input) if result
          return nil
        end
        result = with_timeout { hfa_program&.match_result(input, position) }
        return hfa_match_data(result, input) if result
        return nil if hfa_program
      end

      if input.ascii_only? && (hfa_public_safe? && hfa_match_result_safe? ||
                               hfa_simple_capture_result_safe? || hfa_literal_guard_result_safe? ||
                               hfa_positive_literal_guard_result_safe? || hfa_positive_lookbehind_result_safe? ||
                               hfa_negative_lookbehind_result_safe? || hfa_backref_result_safe? ||
                               hfa_conditional_result_safe? || hfa_subexpression_result_safe? ||
                               hfa_nested_literal_capture_result_safe? || hfa_nested_repeated_capture_result_safe? ||
                               hfa_adjacent_nested_repeated_capture_result_safe? ||
                               hfa_repeated_class_capture_result_safe?)
        result = with_timeout { hfa_program&.match_result(input, position) }
        return hfa_match_data(result, input) if result
        return nil if hfa_program
      end

      codegen_match(input, position)
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

    # Experimental generated matcher surface used during migration validation.
    def codegen_match?(input, position = 0)
      with_timeout do
        codegen_program.search(input, normalize_match_position(input, position), capture: false) == true
      end
    end

    def codegen_match(input, position = 0)
      start = normalize_match_position(input, position)
      result = with_timeout { codegen_program.search(input, start, capture: true) }
      Codegen::MatchAdapter.build(result, input, self, named_captures)
    end

    def codegen_scan(input)
      matches = []
      position = 0
      while position <= input.length
        match = codegen_match(input, position)
        if match
          matches << match
          position = [match.end(0), position + 1].max
        else
          position += 1
        end
      end
      matches
    end

    def codegen_each_match(input, &block)
      return enum_for(__method__, input) unless block

      codegen_each_result(input) do |result|
        block.call(Codegen::MatchAdapter.build(result, input, self, named_captures))
      end
    end

    def codegen_each_result(input, &block)
      return enum_for(__method__, input) unless block

      codegen_program.each_match(input, 0, capture: true) { |result| block.call(result) }
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

    def timeout_unconfigured?
      @timeout.nil? && self.class.timeout.nil?
    end

    def codegen_program
      @codegen_program ||= Codegen::GeneratedProgram.prepared(@ast, options: @options, analysis: @analysis)
    end

    def hfa_program
      return @hfa_program if defined?(@hfa_program)

      unit = Codegen::Optimization.compile_prepared(@ast, @options, encoding)
      @hfa_program = HybridAutomata.compile_unit(unit)
    rescue HybridAutomata::UnsupportedPattern
      @hfa_program = false
    end

    def hfa_public_safe?
      return @hfa_public_safe if defined?(@hfa_public_safe)

      @hfa_public_safe = if !@pattern.ascii_only? || @options.include?("ignorecase")
                           false
                         elsif @ast.is_a?(AST::Sequence) && @ast.parts.length != 1 &&
                               @ast.parts.any? { |part| class_run_result_node?(part) } &&
                               !literal_class_literal_ast? && !class_run_chain_ast? &&
                               !adjacent_class_run_ast? && !class_run_triple_ast?
                           false
                         elsif @ast.is_a?(AST::Sequence) && @ast.parts.length == 1 &&
                               class_run_result_node?(@ast.parts.first) &&
                               !selective_class_run_node?(@ast.parts.first)
                           false
                         else
                           hfa_public_safe_node?(@ast)
                         end
    end

    def hfa_match_question_safe?
      return @hfa_match_question_safe if defined?(@hfa_match_question_safe)
      return false unless @pattern.ascii_only?
      return false if @timeout

      program = hfa_program
      @hfa_match_question_safe = if program && hfa_possessive_literal_safe?
                                   program
                                 elsif hfa_contains_possessive_quantifier? || hfa_always_fails?
                                   false
                                 else
                                   program
                                 end

      @hfa_match_question_safe
    end

    def hfa_possessive_literal_safe?
      parts = @ast.is_a?(AST::Sequence) ? @ast.parts : [@ast]
      return false unless parts.length <= 2

      quantifier = parts.first
      quantifier.is_a?(AST::Quantifier) && %i[+ * bounded].include?(quantifier.kind) &&
        %i[possessive possessive_bounded].include?(quantifier.mode) &&
        quantifier.expression.is_a?(AST::Literal) &&
        quantifier.expression.value.ascii_only? &&
        (quantifier.kind != :bounded || quantifier.maximum) &&
        (parts.length == 1 || parts.last.is_a?(AST::Literal))
    end

    def hfa_contains_possessive_quantifier?
      case @ast
      when AST::Quantifier
        @ast.mode == :possessive || hfa_contains_possessive_node?(@ast.expression)
      else
        hfa_contains_possessive_node?(@ast)
      end
    end

    def hfa_contains_possessive_node?(node)
      children = case node
                 when AST::Sequence then node.parts
                 when AST::Alternation then node.branches
                 when AST::Group, AST::OptionGroup, AST::AtomicGroup, AST::Assertion,
                      AST::Absence then [node.body]
                 when AST::Quantifier then [node.expression]
                 when AST::Conditional then [node.condition, node.yes_branch, node.no_branch]
                 else []
                 end
      (node.is_a?(AST::Quantifier) && node.mode == :possessive) ||
        children.any? { |child| hfa_contains_possessive_node?(child) }
    end

    def hfa_always_fails?
      @ast.is_a?(AST::Sequence) && @ast.parts.one? &&
        @ast.parts.first.is_a?(AST::Assertion) && @ast.parts.first.kind == :negative &&
        @ast.parts.first.body.is_a?(AST::Sequence) && @ast.parts.first.body.parts.empty?
    end

    def hfa_match_result_safe?
      return @hfa_match_result_safe if defined?(@hfa_match_result_safe)

      @hfa_match_result_safe = hfa_match_result_safe_uncached?
    end

    def hfa_match_result_safe_uncached?
      return true if star_literal_ast? || lazy_star_literal_ast? || fixed_class_run_literal_ast? ||
                     dot_literal_ast? || repeat_literal_ast? || class_run_chain_ast? || class_run_triple_ast?

      @ast.is_a?(AST::Literal) ||
        @ast.is_a?(AST::CharacterClass) || @ast.is_a?(AST::Any) ||
        (@ast.is_a?(AST::Alternation) && @ast.branches.all? { |part| hfa_literal_result_node?(part) }) ||
        (@ast.is_a?(AST::Sequence) &&
          (@ast.parts.all? do |part|
            hfa_literal_result_node?(part) &&
           !part.is_a?(AST::CharacterClass) && !part.is_a?(AST::Any)
          end ||
           (@ast.parts.length == 1 &&
            (@ast.parts.first.is_a?(AST::CharacterClass) || @ast.parts.first.is_a?(AST::Any) ||
             class_run_result_node?(@ast.parts.first))))) ||
        (@ast.is_a?(AST::Quantifier) && @ast.mode == :greedy &&
         @ast.expression.is_a?(AST::Literal))
    end

    def hfa_unicode_match_result_safe?
      return @hfa_unicode_match_safe if defined?(@hfa_unicode_match_safe)
      @hfa_unicode_match_safe = if @options.include?("ignorecase") ||
                                  !@ast.is_a?(AST::Sequence) || !@ast.parts.one?
                                 false
                               else
                                 node = @ast.parts.first
                                 node.is_a?(AST::Quantifier) && node.kind == :+ && node.mode == :greedy &&
                                   (node.expression.is_a?(AST::CharacterClass) || node.expression.is_a?(AST::Property))
                               end
    end

    def hfa_unicode_literal_result_safe?
      return false if @options.include?("ignorecase")
      return false unless @ast.is_a?(AST::Sequence)
      return false unless @ast.parts.all? { |part| part.is_a?(AST::Literal) }

      literal = literal_ast_value(@ast)
      literal && literal.each_codepoint.any? { |codepoint| codepoint > 0xFF } && hfa_program
    end

    def hfa_ignorecase_literal_result_safe?
      return @hfa_ignorecase_literal_safe if defined?(@hfa_ignorecase_literal_safe)

      literal = literal_ast_value(@ast)
      @hfa_ignorecase_literal_safe = if @options.include?("ignorecase") && literal&.ascii_only? &&
                                       literal.bytesize.positive?
                                      hfa_program
                                    else
                                      false
                                    end
    end

    def hfa_exact_literal_result_safe?
      return @hfa_exact_literal_safe if defined?(@hfa_exact_literal_safe)
      literal = hfa_exact_literal_value
      @hfa_exact_literal_safe = literal && literal.bytesize.positive? && literal.ascii_only? &&
                                !@options.include?("ignorecase")
    end

    def hfa_unicode_exact_literal_result_safe?
      return @hfa_unicode_exact_literal_safe if defined?(@hfa_unicode_exact_literal_safe)
      literal = hfa_exact_literal_value
      @hfa_unicode_exact_literal_safe = literal && literal.bytesize.positive? &&
                                        literal.each_codepoint.any? { |codepoint| codepoint > 0xFF } &&
                                        !@options.include?("ignorecase")
    end

    def hfa_exact_literal_value
      return @hfa_exact_literal_value if defined?(@hfa_exact_literal_value)
      @hfa_exact_literal_value = if @ast.is_a?(AST::Literal) || @ast.is_a?(AST::Sequence)
                                   literal_ast_value(@ast)
                                 end
    end

    def hfa_word_boundary_literal_result_safe?
      return @hfa_word_boundary_literal_safe if defined?(@hfa_word_boundary_literal_safe)
      parts = @ast.is_a?(AST::Sequence) ? @ast.parts : []
      @hfa_word_boundary_literal_safe = if parts.length >= 3 &&
                                          parts.first.is_a?(AST::Escape) && parts.first.kind == :word_boundary &&
                                          parts.last.is_a?(AST::Escape) && parts.last.kind == :word_boundary &&
                                          parts[1...-1].all? { |part| part.is_a?(AST::Literal) } &&
                                          @options.none? { |option| option == "ignorecase" }
                                         parts[1...-1].map(&:value).join
                                       else
                                         false
                                       end
    end

    def hfa_word_boundary_literal_match_result(input, position)
      literal = hfa_word_boundary_literal_result_safe?
      candidate = input.index(literal, position)
      while candidate
        finish = candidate + literal.bytesize
        before_word = candidate.positive? && CharacterPredicates.word?(input.getbyte(candidate - 1).chr)
        after_word = finish < input.bytesize && CharacterPredicates.word?(input.getbyte(finish).chr)
        return [candidate, finish, []] unless before_word || after_word

        candidate = input.index(literal, candidate + 1)
      end
      nil
    end

    def hfa_literal_assertion_result_safe?
      return @hfa_literal_assertion_safe if defined?(@hfa_literal_assertion_safe)
      parts = @ast.is_a?(AST::Sequence) ? @ast.parts : []
      @hfa_literal_assertion_safe = if parts.length >= 2 && @options.none? { |option| option == "ignorecase" }
                                      assertion = parts.first
                                      body = parts[1..]
                                      if assertion.is_a?(AST::Assertion) &&
                                         %i[positive_lookbehind negative_lookbehind].include?(assertion.kind)
                                        [body.map { |node| literal_ast_value(node) }.then { |values| values.all? ? values.join : nil },
                                         assertion.kind, literal_ast_value(assertion.body)]
                                      else
                                        assertion = parts.last
                                        body = parts[0...-1]
                                        if assertion.is_a?(AST::Assertion) &&
                                           %i[positive negative].include?(assertion.kind)
                                          [body.map { |node| literal_ast_value(node) }.then { |values| values.all? ? values.join : nil },
                                           assertion.kind, literal_ast_value(assertion.body)]
                                        end
                                      end
                                    end
      values = @hfa_literal_assertion_safe
      @hfa_literal_assertion_safe = false unless values &&
                                                [values[0], values[2]].all? do |value|
                                                  value.is_a?(String) && value.ascii_only? && value.bytesize.positive?
                                                end
      @hfa_literal_assertion_safe
    end

    def hfa_literal_assertion_match_result(input, position)
      literal, kind, guard = hfa_literal_assertion_result_safe?
      candidate = input.index(literal, position)
      while candidate
        finish = candidate + literal.bytesize
        matches = case kind
                  when :positive_lookbehind
                    candidate >= guard.bytesize && input.byteslice(candidate - guard.bytesize, guard.bytesize) == guard
                  when :negative_lookbehind
                    candidate < guard.bytesize || input.byteslice(candidate - guard.bytesize, guard.bytesize) != guard
                  when :positive
                    input.byteslice(finish, guard.bytesize) == guard
                  when :negative
                    input.byteslice(finish, guard.bytesize) != guard
                  end
        return [candidate, finish, []] if matches

        candidate = input.index(literal, candidate + 1)
      end
      nil
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
      candidate = input.index(unit, position)
      while candidate
        finish = candidate
        finish += unit.bytesize while input.byteslice(finish, unit.bytesize) == unit
        return [candidate, finish + suffix.value.bytesize, []] if input.byteslice(finish, suffix.value.bytesize) == suffix.value

        candidate = input.index(unit, candidate + 1)
      end
      nil
    end

    def hfa_ignorecase_literal_match_result(input, position)
      literal = literal_ast_value(@ast)
      folded_input = input.downcase
      start = folded_input.index(literal.downcase, position)
      start && [start, start + literal.bytesize, []]
    end

    def hfa_ignorecase_literal_match?(input, position)
      literal = hfa_ignorecase_literal_value
      hfa_ignorecase_literal_variants.any? do |variant|
        candidate = input.index(variant, position)
        while candidate
          return true if input.byteslice(candidate, literal.bytesize).casecmp?(literal)

          candidate = input.index(variant, candidate + 1)
        end
        false
      end
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

    def hfa_match_reset_literal_match?(input, position)
      prefix, suffix = hfa_match_reset_literal_parts
      candidate = input.index(prefix, position)
      while candidate
        return true if input.byteslice(candidate + prefix.bytesize, suffix.bytesize) == suffix

        candidate = input.index(prefix, candidate + 1)
      end
      false
    end

    def hfa_match_reset_literal_combined_literal
      return @hfa_match_reset_literal_combined_literal if defined?(@hfa_match_reset_literal_combined_literal)

      prefix, suffix = hfa_match_reset_literal_parts
      @hfa_match_reset_literal_combined_literal = if prefix&.ascii_only? && suffix&.ascii_only? &&
                                                     prefix.bytesize.positive? && suffix.bytesize.positive?
                                                    prefix + suffix
                                                  end
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

    def hfa_class_run_positive_lookahead_match?(input, position)
      left_table, separator, right_table = hfa_class_run_positive_lookahead_tables
      separator_position = input.index(separator, position + 1)
      while separator_position
        left = separator_position
        left -= 1 while left > position && left_table[input.getbyte(left - 1)]
        right = separator_position + separator.bytesize
        return true if left < separator_position && right < input.bytesize && right_table[input.getbyte(right)]

        separator_position = input.index(separator, separator_position + 1)
      end
      false
    end

    def hfa_unicode_ignorecase_literal_result_safe?
      return @hfa_unicode_ignorecase_literal_safe if defined?(@hfa_unicode_ignorecase_literal_safe)
      literal = literal_ast_value(@ast)
      @hfa_unicode_ignorecase_literal_safe = if @options.include?("ignorecase") && literal &&
                                               !literal.ascii_only? && literal.bytesize.positive?
                                              true
                                            else
                                              false
                                            end
    end

    def hfa_unicode_ignorecase_literal_match_result(input, position)
      literal = hfa_unicode_ignorecase_literal_fold
      folded_input = input.downcase
      character_start = folded_input.index(literal, position)
      return unless character_start

      offsets = [0]
      input.each_char { |character| offsets << offsets[-1] + character.bytesize }
      character_finish = character_start + literal.length
      [offsets[character_start], offsets[character_finish], []]
    end

    def hfa_unicode_ignorecase_literal_match?(input, position)
      input.downcase.index(hfa_unicode_ignorecase_literal_fold, position) != nil
    end

    def hfa_unicode_ignorecase_literal_fold
      return @hfa_unicode_ignorecase_literal_fold if defined?(@hfa_unicode_ignorecase_literal_fold)

      @hfa_unicode_ignorecase_literal_fold = literal_ast_value(@ast)&.downcase
    end

    def hfa_captured_class_run_chain_result_safe?
      layout = hfa_simple_capture_layout
      return false unless layout.is_a?(Array) && layout.length == 3

      layout[0][0] == :class_run && layout[1][0] == :literal && layout[2][0] == :class_run
    end

    def hfa_captured_class_run_chain_match?(input, position)
      layout = hfa_simple_capture_layout
      left_table = layout[0][1]
      separator = layout[1][1]
      right_table = layout[2][1]
      separator_position = input.index(separator, position)
      while separator_position
        left = separator_position
        left -= 1 while left > position && left_table[input.getbyte(left - 1)]
        right = separator_position + separator.bytesize
        right += 1 while right < input.bytesize && right_table[input.getbyte(right)]
        return true if left < separator_position && right > separator_position + separator.bytesize

        separator_position = input.index(separator, separator_position + 1)
      end
      false
    end

    def hfa_fixed_literal_capture_result_safe?
      layout = hfa_simple_capture_layout
      return false unless layout.is_a?(Array) && layout.any? { |kind, _value, number| kind == :literal && number }

      layout.all? { |kind, value, _number| kind == :literal && value }
    end

    def hfa_fixed_literal_capture_match?(input, position)
      literal = hfa_simple_capture_layout.map { |_kind, value, _number| value }.join
      !input.b.index(literal.b, position).nil?
    end

    def hfa_unicode_fixed_literal_capture_literal
      return @hfa_unicode_fixed_literal_capture_literal if defined?(@hfa_unicode_fixed_literal_capture_literal)

      layout = hfa_simple_capture_layout
      @hfa_unicode_fixed_literal_capture_literal = if layout.is_a?(Array) &&
                                                      layout.all? { |kind, value, _number| kind == :literal && value } &&
                                                      !@pattern.ascii_only?
                                                     layout.map { |_kind, value, _number| value }.join
                                                   end
    end

    def hfa_ascii_unicode_run_result_safe?
      return @hfa_ascii_unicode_run_safe if defined?(@hfa_ascii_unicode_run_safe)

      node = @ast.is_a?(AST::Sequence) && @ast.parts.one? ? @ast.parts.first : nil
      @hfa_ascii_unicode_run_safe = if !@options.include?("ignorecase") && node.is_a?(AST::Quantifier) &&
                                      node.kind == :+ && node.mode == :greedy &&
                                      node.expression.is_a?(AST::Property)
                                     !hfa_ascii_unicode_run_table.nil?
                                   else
                                     false
                                   end
    end

    def hfa_ascii_unicode_run_table
      return @hfa_ascii_unicode_run_table if defined?(@hfa_ascii_unicode_run_table)

      node = @ast.parts.first
      @hfa_ascii_unicode_run_table = hfa_capture_class_table(node.expression)
    end

    def hfa_ascii_unicode_run_match?(input, position)
      table = hfa_ascii_unicode_run_table
      cursor = position
      while cursor < input.bytesize
        return true if table[input.getbyte(cursor)]

        cursor += 1
      end
      false
    end

    def hfa_ascii_class_run_result_safe?
      return @hfa_ascii_class_run_safe if defined?(@hfa_ascii_class_run_safe)

      node = @ast.is_a?(AST::Sequence) && @ast.parts.one? ? @ast.parts.first : nil
      @hfa_ascii_class_run_safe = !@options.include?("ignorecase") && node.is_a?(AST::Quantifier) &&
                                  node.kind == :+ && node.mode == :greedy &&
                                  node.expression.is_a?(AST::CharacterClass) &&
                                  !hfa_ascii_class_run_table.nil?
    end

    def hfa_ascii_class_run_table
      return @hfa_ascii_class_run_table if defined?(@hfa_ascii_class_run_table)

      node = @ast.parts.first.expression
      @hfa_ascii_class_run_table = ClassPredicates.compiled(node.value).ascii_table
    end

    def hfa_ascii_class_run_match?(input, position)
      table = hfa_ascii_class_run_table
      cursor = position
      while cursor < input.bytesize
        return true if table[input.getbyte(cursor)]

        cursor += 1
      end
      false
    end

    def hfa_ascii_run_chain_result_safe?
      return @hfa_ascii_run_chain_safe if defined?(@hfa_ascii_run_chain_safe)

      parts = @ast.is_a?(AST::Sequence) ? @ast.parts : []
      valid = !@options.include?("ignorecase") && parts.length == 3 && parts.all? do |part|
        part.is_a?(AST::Quantifier) && part.kind == :+ && part.mode == :greedy &&
          (part.expression.is_a?(AST::CharacterClass) || part.expression.is_a?(AST::Escape))
      end
      @hfa_ascii_run_chain_safe = valid && !hfa_ascii_run_chain_tables.nil?
    end

    def hfa_ascii_run_chain_tables
      return @hfa_ascii_run_chain_tables if defined?(@hfa_ascii_run_chain_tables)

      parts = @ast.parts
      tables = parts.map { |part| hfa_capture_class_table(part.expression) }
      @hfa_ascii_run_chain_tables = tables.all? ? tables.freeze : nil
    end

    def hfa_ascii_run_chain_match?(input, position)
      tables = hfa_ascii_run_chain_tables
      cursor = position
      while cursor < input.bytesize
        starts = cursor
        left = starts
        left += 1 while left < input.bytesize && tables[0][input.getbyte(left)]
        if left > starts
          middle = left
          middle += 1 while middle < input.bytesize && tables[1][input.getbyte(middle)]
          if middle > left
            right = middle
            right += 1 while right < input.bytesize && tables[2][input.getbyte(right)]
            return true if right > middle
          end
        end

        cursor = starts + 1
      end
      false
    end

    def hfa_ascii_adjacent_run_result_safe?
      return @hfa_ascii_adjacent_run_safe if defined?(@hfa_ascii_adjacent_run_safe)

      parts = @ast.is_a?(AST::Sequence) ? @ast.parts : []
      valid = !@options.include?("ignorecase") && parts.length == 2 && parts.all? do |part|
        part.is_a?(AST::Quantifier) && part.kind == :+ && part.mode == :greedy &&
          (part.expression.is_a?(AST::CharacterClass) || part.expression.is_a?(AST::Escape) ||
           part.expression.is_a?(AST::Property))
      end
      @hfa_ascii_adjacent_run_safe = valid && !hfa_ascii_adjacent_run_tables.nil?
    end

    def hfa_ascii_adjacent_run_tables
      return @hfa_ascii_adjacent_run_tables if defined?(@hfa_ascii_adjacent_run_tables)

      @hfa_ascii_adjacent_run_tables = @ast.parts.map do |part|
        hfa_capture_class_table(part.expression)
      end
      @hfa_ascii_adjacent_run_tables = nil unless @hfa_ascii_adjacent_run_tables.all?
      @hfa_ascii_adjacent_run_tables&.freeze
    end

    def hfa_ascii_adjacent_run_match?(input, position)
      tables = hfa_ascii_adjacent_run_tables
      cursor = position
      while cursor < input.bytesize
        left = cursor
        left += 1 while left < input.bytesize && tables[0][input.getbyte(left)]
        if left > cursor
          right = left
          right += 1 while right < input.bytesize && tables[1][input.getbyte(right)]
          return true if right > left
        end

        cursor += 1
      end
      false
    end

    def hfa_atomic_literal_match_literal
      return @hfa_atomic_literal_match_literal if defined?(@hfa_atomic_literal_match_literal)

      parts = @ast.is_a?(AST::Sequence) ? @ast.parts : []
      group, suffix = parts
      branches = group.body.branches if group.is_a?(AST::AtomicGroup) &&
                                       group.body.is_a?(AST::Alternation) && suffix.is_a?(AST::Literal)
      values = branches&.map { |branch| literal_ast_value(branch) }
      if values&.all? && values.first&.ascii_only? && suffix.value.ascii_only? && suffix.value.bytesize.positive?
        first = values.first
        @hfa_atomic_literal_match_literal = if values.all? do |value|
          remainder = value.delete_prefix(first)
          remainder.empty? ||
            (remainder.bytesize % suffix.value.bytesize).zero? &&
              remainder == suffix.value * (remainder.bytesize / suffix.value.bytesize)
        end
                                               first + suffix.value
                                             end
      else
        @hfa_atomic_literal_match_literal = nil
      end
    end

    def hfa_subexpression_literal_match_literal
      return @hfa_subexpression_literal_match_literal if defined?(@hfa_subexpression_literal_match_literal)

      parts = @ast.is_a?(AST::Sequence) ? @ast.parts : []
      group, call = parts
      valid = group.is_a?(AST::Group) && group.capture && group.name &&
              call.is_a?(AST::SubexpressionCall) && call.identifier.to_s == group.name.to_s
      literal = valid ? literal_ast_value(group.body) : nil
      @hfa_subexpression_literal_match_literal = if literal&.ascii_only? && literal.bytesize.positive?
                                                  literal + literal
                                                  end
    end

    def hfa_greedy_dot_star_literal_parts
      return @hfa_greedy_dot_star_literal_parts if defined?(@hfa_greedy_dot_star_literal_parts)

      parts = @ast.is_a?(AST::Sequence) ? @ast.parts : []
      prefix, repeat, suffix = parts
      valid = prefix.is_a?(AST::Literal) && repeat.is_a?(AST::Quantifier) &&
              repeat.kind == :* && repeat.mode == :greedy && repeat.expression.is_a?(AST::Any) &&
              suffix.is_a?(AST::Literal) && prefix.value.ascii_only? && suffix.value.ascii_only? &&
              prefix.value.bytesize.positive? && suffix.value.bytesize.positive?
      @hfa_greedy_dot_star_literal_parts = valid ? [prefix.value, suffix.value, @options.include?("multiline")].freeze : nil
    end

    def hfa_greedy_dot_star_literal_match?(input, position, parts)
      prefix, suffix, allow_newline = parts
      candidate = input.index(prefix, position)
      while candidate
        suffix_position = input.index(suffix, candidate + prefix.bytesize)
        while suffix_position
          newline = input.index("\n", candidate + prefix.bytesize)
          return true if allow_newline || newline.nil? || newline >= suffix_position

          suffix_position = input.index(suffix, suffix_position + 1)
        end
        candidate = input.index(prefix, candidate + 1)
      end
      false
    end

    def hfa_lazy_dot_star_literal_parts
      return @hfa_lazy_dot_star_literal_parts if defined?(@hfa_lazy_dot_star_literal_parts)

      parts = @ast.is_a?(AST::Sequence) ? @ast.parts : []
      prefix, repeat, suffix = parts
      valid = prefix.is_a?(AST::Literal) && repeat.is_a?(AST::Quantifier) &&
              repeat.kind == :* && repeat.mode == :lazy && repeat.expression.is_a?(AST::Any) &&
              suffix.is_a?(AST::Literal) && prefix.value.ascii_only? && suffix.value.ascii_only? &&
              prefix.value.bytesize.positive? && suffix.value.bytesize.positive? &&
              !@options.include?("ignorecase")
      @hfa_lazy_dot_star_literal_parts = valid ? [prefix.value, suffix.value, @options.include?("multiline")].freeze : nil
    end

    def hfa_literal_conditional_result_safe?
      return @hfa_literal_conditional_safe if defined?(@hfa_literal_conditional_safe)

      yes, no = hfa_literal_conditional_parts
      @hfa_literal_conditional_safe = yes&.ascii_only? && no&.ascii_only? &&
                                      yes.bytesize.positive? && no.bytesize.positive?
    end

    def hfa_literal_conditional_parts
      return @hfa_literal_conditional_parts if defined?(@hfa_literal_conditional_parts)

      parts = @ast.is_a?(AST::Sequence) ? @ast.parts : []
      optional, conditional = parts
      capture = optional&.expression if optional.is_a?(AST::Quantifier) && optional.kind == :"?"
      yes = conditional&.yes_branch if conditional.is_a?(AST::Conditional)
      no = conditional&.no_branch if conditional.is_a?(AST::Conditional)
      valid = parts.length == 2 && optional.is_a?(AST::Quantifier) && optional.kind == :"?" &&
              optional.mode == :greedy && capture.is_a?(AST::Group) && capture.capture &&
              conditional.is_a?(AST::Conditional) && conditional.condition == [capture.number, false]
      @hfa_literal_conditional_parts = if valid
                                         [literal_ast_value(yes), literal_ast_value(no)].freeze
                                       else
                                         [nil, nil].freeze
                                       end
    end

    def hfa_literal_conditional_match?(input, position)
      yes, no = hfa_literal_conditional_parts
      !input.index(yes, position).nil? || !input.index(no, position).nil?
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

    def hfa_repeated_class_backref_match?(input, position)
      table, separator = hfa_repeated_class_backref_parts
      separator_position = input.index(separator, position + 1)
      while separator_position
        left = separator_position
        left -= 1 while left > position && table[input.getbyte(left - 1)]
        length = separator_position - left
        if length.positive? && input.byteslice(separator_position + separator.bytesize, length) ==
           input.byteslice(left, length)
          return true
        end

        separator_position = input.index(separator, separator_position + 1)
      end
      false
    end

    def hfa_anchored_class_run_result_safe?
      return @hfa_anchored_class_run_safe if defined?(@hfa_anchored_class_run_safe)

      parts = @ast.is_a?(AST::Sequence) ? @ast.parts : []
      run = parts[1]
      valid = parts.length == 3 && parts[0].is_a?(AST::Anchor) &&
              parts[0].kind == :anchor_absolute_start && parts[2].is_a?(AST::Anchor) &&
              parts[2].kind == :anchor_absolute_end && run.is_a?(AST::Quantifier) &&
              run.kind == :+ && run.mode == :greedy &&
              run.expression.is_a?(AST::CharacterClass)
      @hfa_anchored_class_run_safe = valid && !hfa_anchored_class_run_table.nil?
    end

    def hfa_anchored_class_run_table
      return @hfa_anchored_class_run_table if defined?(@hfa_anchored_class_run_table)

      @hfa_anchored_class_run_table = ClassPredicates.compiled(@ast.parts[1].expression.value).ascii_table
    end

    def hfa_anchored_class_run_match?(input, position)
      return false unless position.zero? && input.bytesize.positive?

      table = hfa_anchored_class_run_table
      cursor = 0
      while cursor < input.bytesize
        return false unless table[input.getbyte(cursor)]

        cursor += 1
      end
      true
    end

    def hfa_literal_alternation_result_safe?
      return @hfa_literal_alternation_safe if defined?(@hfa_literal_alternation_safe)

      alternatives = hfa_literal_alternation_values
      @hfa_literal_alternation_safe = alternatives.length > 1 && alternatives.all? do |value|
        value.ascii_only? && value.bytesize.positive?
      end
    end

    def hfa_literal_alternation_values
      return @hfa_literal_alternation_values if defined?(@hfa_literal_alternation_values)

      branches = @ast.is_a?(AST::Alternation) ? @ast.branches : []
      @hfa_literal_alternation_values = branches.map { |branch| literal_ast_value(branch) }.freeze
    end

    def hfa_literal_alternation_match?(input, position)
      hfa_literal_alternation_values.any? { |value| !input.index(value, position).nil? }
    end

    def hfa_dot_literal_result_safe?
      return @hfa_dot_literal_safe if defined?(@hfa_dot_literal_safe)

      prefix, suffix = hfa_dot_literal_parts
      @hfa_dot_literal_safe = !@options.include?("ignorecase") && prefix&.ascii_only? && suffix&.ascii_only? &&
                              prefix.bytesize == 1 && suffix.bytesize == 1
    end

    def hfa_dot_literal_parts
      return @hfa_dot_literal_parts if defined?(@hfa_dot_literal_parts)

      parts = @ast.is_a?(AST::Sequence) ? @ast.parts : []
      prefix, wildcard, suffix = parts
      valid = parts.length == 3 && prefix.is_a?(AST::Literal) && wildcard.is_a?(AST::Any) &&
              suffix.is_a?(AST::Literal)
      @hfa_dot_literal_parts = if valid
                                 [prefix.value, suffix.value, @options.include?("multiline")].freeze
                               else
                                 [nil, nil, false].freeze
                               end
    end

    def hfa_dot_literal_match?(input, position)
      prefix, suffix, allow_newline = hfa_dot_literal_parts
      candidate = input.index(prefix, position)
      while candidate
        middle = candidate + 1
        finish = candidate + 2
        if finish < input.bytesize && (allow_newline || input.getbyte(middle) != 10) &&
           input.getbyte(finish) == suffix.getbyte(0)
          return true
        end

        candidate = input.index(prefix, candidate + 1)
      end
      false
    end

    def hfa_unicode_property_run_result_safe?
      return @hfa_unicode_property_run_safe if defined?(@hfa_unicode_property_run_safe)

      node = @ast.is_a?(AST::Sequence) && @ast.parts.one? ? @ast.parts.first : nil
      safe = !@options.include?("ignorecase") && node.is_a?(AST::Quantifier) &&
             node.kind == :+ && node.mode == :greedy &&
             node.expression.is_a?(AST::Property) && node.expression.name.sub("Is", "").sub("^", "") == "Hiragana" &&
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

    def hfa_unicode_property_run_match?(input, position)
      predicate, negated = hfa_unicode_property_run_spec
      if !negated && @hfa_unicode_property_run_fast
        index = 0
        input.each_codepoint do |codepoint|
          return true if index >= position && codepoint.between?(0x3040, 0x309f)

          index += 1
        end
        return false
      end
      index = 0
      matcher = hfa_unicode_property_run_matcher
      input.each_codepoint do |codepoint|
        if index >= position && (matcher.call(codepoint, predicate) ^ negated)
          return true
        end

        index += 1
      end
      false
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

    def hfa_unicode_word_class_run_result_safe?
      return @hfa_unicode_word_class_run_safe if defined?(@hfa_unicode_word_class_run_safe)

      node = @ast.is_a?(AST::Sequence) && @ast.parts.one? ? @ast.parts.first : nil
      @hfa_unicode_word_class_run_safe = !@options.include?("ignorecase") && node.is_a?(AST::Quantifier) &&
                                         node.kind == :+ && node.mode == :greedy &&
                                         node.expression.is_a?(AST::CharacterClass) &&
                                         node.expression.value == "[:word:]"
    end

    def hfa_unicode_word_class_run_match?(input, position)
      index = 0
      input.each_codepoint do |codepoint|
        if index >= position && hfa_unicode_word_codepoint?(codepoint)
          return true
        end

        index += 1
      end
      false
    end

    def hfa_unicode_word_codepoint?(codepoint)
      return true if codepoint == 95 || codepoint.between?(48, 57) ||
                     codepoint.between?(65, 90) || codepoint.between?(97, 122)
      return true if codepoint.between?(0x3040, 0x30ff) || codepoint.between?(0x3400, 0x4dbf) ||
                     codepoint.between?(0x4e00, 0x9fff) || codepoint.between?(0xac00, 0xd7af)

      UnicodeProperties.letter?(codepoint.chr(Encoding::UTF_8))
    end

    def hfa_unicode_simple_capture_result_safe?
      return @hfa_unicode_simple_capture_safe if defined?(@hfa_unicode_simple_capture_safe)
      layout = hfa_simple_capture_layout
      @hfa_unicode_simple_capture_safe = if layout && !@pattern.ascii_only? &&
                                           layout.all? { |kind, value, number| kind == :literal && number && value }
                                          hfa_program
                                        else
                                          false
                                        end
    end

    def hfa_unicode_repeated_literal_result_safe?
      return @hfa_unicode_repeated_literal_safe if defined?(@hfa_unicode_repeated_literal_safe)
      @hfa_unicode_repeated_literal_safe = if @options.include?("ignorecase") ||
                                              !@ast.is_a?(AST::Sequence) || !@ast.parts.one?
                                             false
                                           else
                                             quantifier = @ast.parts.first
                                             if quantifier.is_a?(AST::Quantifier) && quantifier.kind == :+ &&
                                                quantifier.mode == :greedy
                                               literal = hfa_unicode_repeated_literal_unit
                                               literal && literal.bytesize.positive? && !literal.ascii_only?
                                             end
                                           end
    end

    def hfa_unicode_repeated_literal_match_result(input, position)
      unit = hfa_unicode_repeated_literal_unit
      unit_bytes = unit.b
      bytes = input.b
      candidate = bytes.index(unit_bytes, position)
      while candidate
        finish = candidate
        finish += unit_bytes.bytesize while bytes.byteslice(finish, unit_bytes.bytesize) == unit_bytes
        return [candidate, finish, []] if finish > candidate

        candidate = bytes.index(unit_bytes, candidate + 1)
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

    def hfa_literal_result_node?(node)
      node.is_a?(AST::Literal) || node.is_a?(AST::CharacterClass) || node.is_a?(AST::Any) ||
        (node.is_a?(AST::Sequence) && node.parts.all? { |part| part.is_a?(AST::Literal) }) ||
        (node.is_a?(AST::Quantifier) && node.mode == :greedy &&
         (node.expression.is_a?(AST::Literal) || class_run_result_node?(node)))
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
      start, finish, captures = result
      if captures.empty? && (capture_offsets = hfa_conditional_capture_offsets(input, start))
        values = capture_offsets.map do |offset|
          offset && input.byteslice(offset[0], offset[1] - offset[0])
        end
        names = hfa_static_capture_names || hfa_capture_names.transform_values(&:last)
        return MatchData.new(input.byteslice(start, finish - start), values,
                             [[start, finish], *capture_offsets], names,
                             MatchData::Context.new(input, self))
      end
      if captures.empty? && (capture_offsets = hfa_subexpression_capture_offsets(input, start))
        values = capture_offsets.map do |offset|
          offset && input.byteslice(offset[0], offset[1] - offset[0])
        end
        names = hfa_static_capture_names || hfa_capture_names.transform_values(&:last)
        return MatchData.new(input.byteslice(start, finish - start), values,
                             [[start, finish], *capture_offsets], names,
                             MatchData::Context.new(input, self))
      end
      if captures.empty? && (capture_offsets = hfa_nested_literal_capture_offsets(input, start, finish))
        values = capture_offsets.map do |offset|
          offset && input.byteslice(offset[0], offset[1] - offset[0])
        end
        names = hfa_static_capture_names || hfa_capture_names.transform_values(&:last)
        return MatchData.new(input.byteslice(start, finish - start), values,
                             [[start, finish], *capture_offsets], names,
                             MatchData::Context.new(input, self))
      end
      if captures.empty? && (capture_offsets = hfa_nested_repeated_capture_offsets(input, start, finish))
        values = capture_offsets.map do |offset|
          offset && input.byteslice(offset[0], offset[1] - offset[0])
        end
        names = hfa_static_capture_names || hfa_capture_names.transform_values(&:last)
        return MatchData.new(input.byteslice(start, finish - start), values,
                             [[start, finish], *capture_offsets], names,
                             MatchData::Context.new(input, self))
      end
      if captures.empty? && (capture_offsets = hfa_adjacent_nested_repeated_capture_offsets(input, start, finish))
        values = capture_offsets.map do |offset|
          offset && input.byteslice(offset[0], offset[1] - offset[0])
        end
        names = hfa_static_capture_names || hfa_capture_names.transform_values(&:last)
        return MatchData.new(input.byteslice(start, finish - start), values,
                             [[start, finish], *capture_offsets], names,
                             MatchData::Context.new(input, self))
      end
      if captures.empty? && (capture_offsets = hfa_repeated_class_capture_offsets(input, start, finish))
        values = capture_offsets.map do |offset|
          offset && input.byteslice(offset[0], offset[1] - offset[0])
        end
        names = hfa_static_capture_names || hfa_capture_names.transform_values(&:last)
        return MatchData.new(input.byteslice(start, finish - start), values,
                             [[start, finish], *capture_offsets], names,
                             MatchData::Context.new(input, self))
      end
      if captures.empty? && (capture_offsets = hfa_simple_capture_offsets(input, start, finish))
        values = capture_offsets.map do |offset|
          offset && input.byteslice(offset[0], offset[1] - offset[0])
        end
        names = hfa_static_capture_names || hfa_capture_names.transform_values do |indices|
          indices.reverse_each.find { |index| capture_offsets[index - 1] } || indices.last
        end
        return MatchData.new(input.byteslice(start, finish - start), values,
                             [[start, finish], *capture_offsets], names,
                             MatchData::Context.new(input, self))
      end
      if captures.any? && captures.all? { |capture| capture.is_a?(Array) && capture.length == 2 }
        values = captures.map { |offset| input.byteslice(offset[0], offset[1] - offset[0]) }
        names = hfa_capture_names.transform_values(&:last)
        return MatchData.new(input.byteslice(start, finish - start), values,
                             [[start, finish], *captures], names,
                             MatchData::Context.new(input, self))
      end
      return MatchData.captureless(input, start, finish, self) if captures.empty?

      MatchData.new(input[start...finish], captures, [[start, finish]], {},
                    MatchData::Context.new(input, self))
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

    def hfa_simple_capture_result_safe?
      hfa_simple_capture_layout && hfa_program
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

      if node.capture && node.body.is_a?(AST::Alternation)
        branches = node.body.branches.map { |branch| literal_ast_value(branch) }
        return [:alternation_literal, branches.freeze, number] if branches.all?
      end

      body = node.body
      body = body.parts.first if body.is_a?(AST::Sequence) && body.parts.one?
      return unless body.is_a?(AST::Quantifier) && body.kind == :+ && body.mode == :greedy

      table = hfa_capture_class_table(body.expression)
      table && [:class_run, table, number]
    end

    def hfa_capture_class_table(node)
      return ClassPredicates.compiled(node.value).ascii_table if node.is_a?(AST::CharacterClass)
      return if node.is_a?(AST::Any)

      if node.is_a?(AST::Escape)
        return 256.times.map do |byte|
          CharacterPredicates.escape_matches?(node.kind, byte.chr(Encoding::ASCII_8BIT))
        end.freeze
      end
      return unless node.is_a?(AST::Property)
      return unless UnicodeProperties::SUPPORTED.include?(node.name.sub("Is", "").sub("^", ""))

      256.times.map do |byte|
        matched = UnicodeProperties.matches?(node.name, byte.chr(Encoding::ASCII_8BIT))
        node.negated ? !matched : matched
      end.freeze
    end

    def hfa_capture_names
      @hfa_capture_names ||= CaptureNameCollector.indices(@ast)
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
      offsets = Array.new(layout.filter_map { |_kind, _value, number| number }.max || 0)
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

      ascii_safe = input.ascii_only? &&
                   (hfa_exact_literal_result_safe? || hfa_public_safe? || hfa_negative_literal_guard_safe? || hfa_simple_capture_result_safe? ||
                   hfa_word_boundary_literal_result_safe? || hfa_literal_assertion_result_safe? ||
                   hfa_possessive_literal_string_result_safe? ||
                   hfa_backref_result_safe? || hfa_conditional_result_safe? || hfa_subexpression_result_safe? ||
                   hfa_ignorecase_literal_result_safe? ||
                   hfa_positive_literal_guard_result_safe? || hfa_positive_lookbehind_result_safe? ||
                   hfa_negative_lookbehind_result_safe? ||
                    hfa_nested_literal_capture_result_safe? || hfa_nested_repeated_capture_result_safe? ||
                    hfa_adjacent_nested_repeated_capture_result_safe? ||
                    hfa_repeated_class_capture_result_safe?)
      unicode_safe = !input.ascii_only? &&
                     (hfa_unicode_match_result_safe? || hfa_unicode_literal_result_safe? ||
                      hfa_unicode_ignorecase_literal_result_safe? ||
                      hfa_unicode_simple_capture_result_safe? ||
                      hfa_unicode_repeated_literal_result_safe?)
      return false unless (ascii_safe || unicode_safe) && hfa_iterator_safe?

      program = hfa_program
      return false unless program

      if hfa_possessive_literal_string_result_safe?
        position = 0
        while (result = hfa_possessive_literal_string_match_result(input, position))
          block.call(result)
          position = result[1]
        end
      elsif hfa_literal_assertion_result_safe?
        position = 0
        while (result = hfa_literal_assertion_match_result(input, position))
          block.call(result)
          position = result[1]
        end
      elsif hfa_word_boundary_literal_result_safe?
        position = 0
        while (result = hfa_word_boundary_literal_match_result(input, position))
          block.call(result)
          position = result[1]
        end
      elsif hfa_exact_literal_result_safe? || hfa_unicode_exact_literal_result_safe?
        literal = hfa_exact_literal_value
        position = 0
        while (start = if hfa_exact_literal_result_safe?
                         input.index(literal, position)
                       else
                         input.b.index(literal.b, position)
                       end)
          finish = start + literal.bytesize
          block.call([start, finish, []])
          position = finish
        end
      elsif hfa_unicode_ignorecase_literal_result_safe?
        position = 0
        while (result = hfa_unicode_ignorecase_literal_match_result(input, input.byteslice(0, position).to_s.length))
          block.call(result)
          position = result[1]
        end
      elsif hfa_ignorecase_literal_result_safe?
        folded_input = input.downcase
        literal = literal_ast_value(@ast).downcase
        position = 0
        while (start = folded_input.index(literal, position))
          finish = start + literal.bytesize
          block.call([start, finish, []])
          position = finish
        end
      elsif hfa_unicode_repeated_literal_result_safe?
        position = 0
        while (result = hfa_unicode_repeated_literal_match_result(input, position))
          block.call([result[0], result[1], result[2]])
          position = result[1]
        end
      elsif hfa_simple_capture_result_safe?
        program.each_match_result(input, 0) do |result|
          captures = hfa_simple_capture_offsets(input, result[0], result[1])
          block.call([result[0], result[1], captures || result[2]])
        end
      elsif hfa_subexpression_result_safe?
        program.each_match_result(input, 0) do |result|
          captures = hfa_subexpression_capture_offsets(input, result[0])
          block.call([result[0], result[1], captures || result[2]])
        end
      elsif hfa_nested_literal_capture_result_safe?
        program.each_match_result(input, 0) do |result|
          captures = hfa_nested_literal_capture_offsets(input, result[0], result[1])
          block.call([result[0], result[1], captures || result[2]])
        end
      elsif hfa_nested_repeated_capture_result_safe?
        program.each_match_result(input, 0) do |result|
          captures = hfa_nested_repeated_capture_offsets(input, result[0], result[1])
          block.call([result[0], result[1], captures || result[2]])
        end
      elsif hfa_adjacent_nested_repeated_capture_result_safe?
        program.each_match_result(input, 0) do |result|
          captures = hfa_adjacent_nested_repeated_capture_offsets(input, result[0], result[1])
          block.call([result[0], result[1], captures || result[2]])
        end
      elsif hfa_repeated_class_capture_result_safe?
        program.each_match_result(input, 0) do |result|
          captures = hfa_repeated_class_capture_offsets(input, result[0], result[1])
          block.call([result[0], result[1], captures || result[2]])
        end
      else
        program.each_match_result(input, 0, &block)
      end
      true
    end

    def hfa_iterator_safe?
      return true if hfa_exact_literal_result_safe? || hfa_unicode_exact_literal_result_safe? ||
                     hfa_literal_assertion_result_safe? || hfa_possessive_literal_string_result_safe? ||
                     hfa_word_boundary_literal_result_safe? ||
                     hfa_negative_literal_guard_safe? || hfa_positive_literal_guard_result_safe? ||
                     hfa_positive_lookbehind_result_safe? || hfa_negative_lookbehind_result_safe? ||
                     hfa_simple_capture_result_safe? || hfa_backref_result_safe? ||
                      hfa_conditional_result_safe? || hfa_subexpression_result_safe? ||
                      hfa_nested_literal_capture_result_safe? || hfa_nested_repeated_capture_result_safe? ||
                      hfa_adjacent_nested_repeated_capture_result_safe? ||
                      hfa_unicode_repeated_literal_result_safe? || hfa_ignorecase_literal_result_safe? ||
                      hfa_unicode_ignorecase_literal_result_safe? ||
                      hfa_repeated_class_capture_result_safe?

      return true if star_literal_ast? || lazy_star_literal_ast? || repeated_alternation_ast? ||
                     fixed_class_run_literal_ast? || dot_literal_ast? || repeat_literal_ast? ||
                     class_run_chain_ast? || class_run_triple_ast?

      @ast.is_a?(AST::Literal) ||
        @ast.is_a?(AST::CharacterClass) || @ast.is_a?(AST::Any) ||
        (@ast.is_a?(AST::Quantifier) && @ast.mode == :greedy &&
         (@ast.expression.is_a?(AST::Literal) || class_run_result_node?(@ast))) ||
        (@ast.is_a?(AST::Alternation) && @ast.branches.all? { |part| hfa_iterator_node?(part) }) ||
        (@ast.is_a?(AST::Sequence) &&
          (@ast.parts.all? do |part|
            part.is_a?(AST::Literal) ||
           (part.is_a?(AST::Quantifier) && part.mode == :greedy && part.expression.is_a?(AST::Literal))
          end ||
           (@ast.parts.length == 3 && @ast.parts[0].is_a?(AST::Literal) &&
            class_run_result_node?(@ast.parts[1]) && @ast.parts[2].is_a?(AST::Literal)) ||
           (@ast.parts.length == 1 &&
            (@ast.parts.first.is_a?(AST::CharacterClass) || @ast.parts.first.is_a?(AST::Any) ||
            class_run_result_node?(@ast.parts.first)))))
    end

    def hfa_negative_literal_guard_safe?
      return false unless @ast.is_a?(AST::Sequence) && @ast.parts.length >= 2

      body = @ast.parts[0...-1]
      assertion = @ast.parts[-1]
      return false unless assertion.is_a?(AST::Assertion) && assertion.kind == :negative

      guard = assertion.body
      guard_literal = guard.is_a?(AST::Literal) ||
                      (guard.is_a?(AST::Sequence) && guard.parts.all? { |part| part.is_a?(AST::Literal) })
      guard_literal && body.all? { |part| hfa_iterator_node?(part) }
    end

    def hfa_literal_guard_result_safe?
      return false unless hfa_negative_literal_guard_safe?

      body = @ast.parts[0...-1]
      body.all? { |part| part.is_a?(AST::Literal) }
    end

    def hfa_positive_literal_guard_result_safe?
      return false unless @ast.is_a?(AST::Sequence) && @ast.parts.length >= 2

      body = @ast.parts[0...-1]
      assertion = @ast.parts[-1]
      assertion.is_a?(AST::Assertion) && assertion.kind == :positive &&
        assertion.body.is_a?(AST::Sequence) && assertion.body.parts.all? { |part| part.is_a?(AST::Literal) } &&
        body.all? { |part| part.is_a?(AST::Literal) }
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

    def hfa_backref_result_safe?
      parts = @ast.is_a?(AST::Sequence) ? @ast.parts : []
      return false unless hfa_program
      return false unless parts.length.between?(2, 3)
      return false unless parts[0].is_a?(AST::Group) && parts[0].capture
      return false unless parts[-1].is_a?(AST::Backreference)
      return false unless parts.length == 2 || parts[1].is_a?(AST::Literal)

      parts[0].body.is_a?(AST::Sequence)
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
      root = if @ast.is_a?(AST::Sequence) && @ast.parts.one?
               @ast.parts.first
             else
               @ast
             end
      return false unless root.is_a?(AST::Group) && root.capture
      return false if @options.include?("ignorecase")

      captures = []
      value = hfa_nested_literal_value(root, captures)
      value && captures.length > 1 && hfa_program
    end

    def hfa_nested_repeated_capture_result_safe?
      root, = hfa_nested_repeated_capture_parts
      return false unless root
      return false unless root.is_a?(AST::Group) && root.capture
      body = root.body
      body = body.parts.first if body.is_a?(AST::Sequence) && body.parts.one?
      return false unless body.is_a?(AST::Quantifier) && body.kind == :+ && body.mode == :greedy

      inner = body.expression
      inner.is_a?(AST::Group) && inner.capture && hfa_repeated_unit_value(inner.body) && hfa_program
    end

    def hfa_nested_repeated_capture_offsets(input, start, finish)
      return unless hfa_nested_repeated_capture_result_safe?

      root, suffix = hfa_nested_repeated_capture_parts
      repeat_finish = finish - suffix.bytesize
      return unless suffix.empty? || input.byteslice(repeat_finish, suffix.bytesize) == suffix

      body = root.body.parts.first
      value = hfa_repeated_unit_value(body.expression.body)
      return unless value

      unit = body.expression.body
      lengths = hfa_repeated_match_lengths(unit, input, start, repeat_finish)
      return unless lengths&.any? && lengths.sum == repeat_finish - start

      last_start = repeat_finish - lengths.last
      [[start, repeat_finish], [last_start, repeat_finish]]
    end

    def hfa_nested_repeated_capture_parts
      parts = @ast.is_a?(AST::Sequence) ? @ast.parts : [@ast]
      return [parts.first, ""] if parts.length == 1 && parts.first.is_a?(AST::Group)
      return [parts.first, parts.last.value] if parts.length == 2 && parts.first.is_a?(AST::Group) &&
                                                 parts.last.is_a?(AST::Literal)

      [nil, nil]
    end

    def hfa_adjacent_nested_repeated_capture_result_safe?
      groups = hfa_adjacent_nested_repeated_capture_groups
      groups && hfa_program
    end

    def hfa_adjacent_nested_repeated_capture_groups
      parts = @ast.is_a?(AST::Sequence) ? @ast.parts : []
      return if parts.length < 2
      return unless parts.all? { |part| part.is_a?(AST::Group) && part.capture && hfa_repeated_group_node?(part) }

      parts
    end

    def hfa_adjacent_nested_repeated_capture_offsets(input, start, finish)
      groups = hfa_adjacent_nested_repeated_capture_groups
      return unless groups

      units = groups.map { |group| hfa_repeated_group_node_unit(group) }
      boundaries = hfa_adjacent_repeated_boundaries(input, start, finish, units)
      return unless boundaries

      numbers = groups.flat_map do |group|
        [group.number, group.body.parts.first.expression.number]
      end
      offsets = Array.new(numbers.max)
      groups.each_with_index do |group, index|
        group_start, group_finish = boundaries[index], boundaries[index + 1]
        body = group.body.parts.first
        inner = body.expression
        lengths = hfa_repeated_match_lengths(inner.body, input, group_start, group_finish)
        return unless lengths&.any? && lengths.sum == group_finish - group_start

        offsets[group.number - 1] = [group_start, group_finish]
        offsets[inner.number - 1] = [group_finish - lengths.last, group_finish]
      end
      offsets
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
        while input.byteslice(max, unit.bytesize) == unit
          max += unit.bytesize
        end
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
      return unless @ast.is_a?(AST::Sequence) && @ast.parts.length >= 3

      repeated, suffix = @ast.parts[0], @ast.parts[1..]
      return unless repeated.is_a?(AST::Group) && repeated.capture && suffix.length.even?

      pairs = suffix.each_slice(2).to_a
      return unless pairs.all? do |separator, class_group|
        separator.is_a?(AST::Literal) && class_group.is_a?(AST::Group) && class_group.capture
      end

      [repeated, pairs]
    end

    def hfa_repeated_class_capture_result_safe?
      parts = hfa_repeated_class_capture_parts
      return false unless parts

      repeated, pairs = parts
      return false unless hfa_repeated_group_node?(repeated)

      pairs.all? do |_separator, class_group|
        hfa_class_capture_spec(class_group)
      end && hfa_program
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

      repeated, pairs = hfa_repeated_class_capture_parts
      separator_position = input.index(pairs.first.first.value, start)
      return unless separator_position && separator_position < finish

      repeated_body = repeated.body.parts.first
      lengths = hfa_repeated_match_lengths(repeated_body.expression.body, input, start, separator_position)
      return unless lengths&.any? && lengths.sum == separator_position - start

      numbers = [repeated.number, repeated.body.parts.first.expression.number] +
                pairs.flat_map { |_separator, group| [group.number, hfa_class_capture_spec(group)[1]] }.compact
      offsets = Array.new(numbers.max)
      offsets[repeated.number - 1] = [start, separator_position]
      offsets[repeated.body.parts.first.expression.number - 1] =
        [separator_position - lengths.last, separator_position]
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

        table, inner_number = hfa_class_capture_spec(class_group)
        cursor = class_start
        cursor += 1 while cursor < class_finish && table[input.getbyte(cursor)]
        return unless cursor == class_finish

        offsets[class_group.number - 1] = [class_start, class_finish]
        offsets[inner_number - 1] = [class_finish - 1, class_finish] if inner_number
      end
      return unless cursor == finish

      offsets
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

    def hfa_repeated_match_lengths(node, input, start, finish)
      cursor = start
      lengths = []
      while cursor < finish
        length = hfa_nested_literal_match_length(node, input, cursor)
        return unless length&.positive? && cursor + length <= finish

        lengths << length
        cursor += length
      end
      lengths if cursor == finish
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

    def hfa_public_safe_node?(node)
      case node
      when AST::Literal, AST::CharacterClass, AST::Any
        true
      when AST::Property
        UnicodeProperties::SUPPORTED.include?(node.name.sub("Is", "").sub("^", ""))
      when AST::Sequence, AST::Alternation
        children = node.is_a?(AST::Sequence) ? node.parts : node.branches
        children.all? { |part| hfa_public_safe_node?(part) }
      when AST::Group
        !node.capture && hfa_public_safe_node?(node.body)
      when AST::Quantifier
        (node.mode == :greedy || star_literal_result_node?(node) ||
         (node.kind == :* && node.mode == :lazy && node.expression.is_a?(AST::Any))) &&
          (node.expression.is_a?(AST::Literal) || class_run_result_node?(node) ||
           star_literal_result_node?(node) ||
           (node.kind == :* && node.mode == :lazy && node.expression.is_a?(AST::Any))) &&
          hfa_public_safe_node?(node.expression)
      when AST::Escape
        %i[word_boundary digit space word].include?(node.kind)
      when AST::Assertion, AST::Anchor
        false
      else
        false
      end
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
      if binary_pattern && tokens.any? { |token| token.type == :property }
        raise RegexpError, "Unicode properties require a text encoding"
      end

      tokens
    end
  end
end

require_relative "onibi/hybrid_automata"
