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
    end

    def match?(input, position = 0)
      raise TypeError, "no implicit conversion of #{input.class} into String" unless input.is_a?(String)

      validate_encoding!(input)
      if !input.ascii_only? && hfa_unicode_match_result_safe?
        hfa = hfa_program
        return with_timeout { hfa.match?(input, normalize_match_position(input, position)) } if hfa
      end

      hfa = hfa_program if input.ascii_only? && hfa_match_question_safe?
      return with_timeout { hfa.match?(input, normalize_match_position(input, position)) } if hfa

      codegen_match?(input, position)
    end

    def match(input, position = 0)
      raise TypeError, "no implicit conversion of #{input.class} into String" unless input.is_a?(String)

      validate_encoding!(input)

      if !input.ascii_only? && hfa_unicode_match_result_safe?
        result = with_timeout { hfa_program&.match_result(input, position) }
        return hfa_match_data(result, input) if result
        return nil if hfa_program
      end

      if input.ascii_only? && (hfa_public_safe? && hfa_match_result_safe? ||
                               hfa_simple_capture_result_safe? || hfa_literal_guard_result_safe? ||
                               hfa_positive_literal_guard_result_safe? || hfa_positive_lookbehind_result_safe? ||
                               hfa_negative_lookbehind_result_safe? || hfa_backref_result_safe? ||
                               hfa_conditional_result_safe? || hfa_subexpression_result_safe? ||
                               hfa_nested_literal_capture_result_safe?)
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
      return false unless @pattern.ascii_only?
      return false if @options.include?("ignorecase")
      if @ast.is_a?(AST::Sequence) && @ast.parts.length != 1 &&
         @ast.parts.any? { |part| class_run_result_node?(part) } &&
         !literal_class_literal_ast? && !class_run_chain_ast? && !adjacent_class_run_ast? &&
         !class_run_triple_ast?
        return false
      end
      if @ast.is_a?(AST::Sequence) && @ast.parts.length == 1 &&
         class_run_result_node?(@ast.parts.first) &&
         !selective_class_run_node?(@ast.parts.first)
        return false
      end

      hfa_public_safe_node?(@ast)
    end

    def hfa_match_question_safe?
      return false unless @pattern.ascii_only?
      return false if @timeout

      program = hfa_program
      return program if program && hfa_possessive_literal_safe?
      return false if hfa_contains_possessive_quantifier? || hfa_always_fails?

      program
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
      return false if @options.include?("ignorecase")
      return false unless @ast.is_a?(AST::Sequence) && @ast.parts.one?

      node = @ast.parts.first
      return false unless node.is_a?(AST::Quantifier) && node.kind == :+ && node.mode == :greedy

      node.expression.is_a?(AST::CharacterClass) || node.expression.is_a?(AST::Property)
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
      return unless value && input.byteslice(start, value.bytesize) == value && start + value.bytesize == finish

      offsets = Array.new(captures.map(&:first).max)
      captures.each do |capture|
        number = capture.first
        offsets[number - 1] = [start, start + value_for_capture(captures, number).bytesize]
      end
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
                   (hfa_public_safe? || hfa_negative_literal_guard_safe? || hfa_simple_capture_result_safe? ||
                    hfa_backref_result_safe? || hfa_conditional_result_safe? || hfa_subexpression_result_safe? ||
                    hfa_nested_literal_capture_result_safe?)
      unicode_safe = !input.ascii_only? && hfa_unicode_match_result_safe?
      return false unless (ascii_safe || unicode_safe) && hfa_iterator_safe?

      program = hfa_program
      return false unless program

      if hfa_simple_capture_result_safe?
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
      else
        program.each_match_result(input, 0, &block)
      end
      true
    end

    def hfa_iterator_safe?
      return true if hfa_negative_literal_guard_safe? || hfa_simple_capture_result_safe? || hfa_backref_result_safe? ||
                     hfa_conditional_result_safe? || hfa_subexpression_result_safe? ||
                     hfa_nested_literal_capture_result_safe?

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
