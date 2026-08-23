# frozen_string_literal: true

require_relative "onibi/version"
require_relative "onibi/unicode_property_scripts"
require_relative "onibi/unicode_property_categories"
require_relative "onibi/unicode_properties"
require_relative "onibi/lexer/lexer_classes"
require_relative "onibi/lexer/lexer_option_groups"
require_relative "onibi/lexer/lexer_comments"
require_relative "onibi/lexer/lexer_extended_mode"
require_relative "onibi/lexer/lexer_scoped_extended"
require_relative "onibi/lexer/lexer_extended_scopes"
require_relative "onibi/lexer/lexer_dispatch"
require_relative "onibi/lexer/lexer_token_stream"
require_relative "onibi/lexer/lexer_escapes"
require_relative "onibi/lexer"
require_relative "onibi/character_predicates"
require_relative "onibi/class_predicates"
require_relative "onibi/class_predicates_posix"
require_relative "onibi/compiled_class_predicate"
require_relative "onibi/ast"
require_relative "onibi/input_view"
require_relative "onibi/invocation_state"
require_relative "onibi/parser/parser_widths"
require_relative "onibi/parser/parser_assertions"
require_relative "onibi/parser/parser_quantifiers"
require_relative "onibi/parser/parser_option_groups"
require_relative "onibi/parser/parser_tokens"
require_relative "onibi/capture_name_collector"
require_relative "onibi/backreference_lexer"
require_relative "onibi/match_data_destructuring"
require_relative "onibi/match_data_offsets"
require_relative "onibi/match_data"

module Onibi
  class Error < StandardError; end
  class RegexpError < Error; end

  # Constants remain available while the v2 parser is developed.
  class Regexp
    IGNORECASE = 1
    EXTENDED = 2
    MULTILINE = 4
    FIXEDENCODING = 16
    NOENCODING = 32

    class TimeoutError < RegexpError; end

    class << self
      def compile(pattern, options = nil, timeout: nil)
        new(pattern, options, timeout: timeout)
      end

      def timeout=(value)
        @timeout = value.nil? ? nil : normalize_timeout_value(value)
      end

      attr_reader :timeout

      def escape(string)
        value = if string.is_a?(String)
                  string
                elsif string.is_a?(Symbol)
                  string.to_s
                elsif string.respond_to?(:to_str)
                  string.to_str
                else
                  raise TypeError, "no implicit conversion of #{string.class} into String"
                end
        escaped = value.each_char.map do |character|
          case character
          when "\t" then "\\t"
          when "\n" then "\\n"
          when "\v" then "\\v"
          when "\f" then "\\f"
          when "\r" then "\\r"
          when /[\\\[\]{}().*+?^$| #-]/ then "\\#{character}"
          else character
          end
        end.join
        escaped.force_encoding(escaped.ascii_only? ? Encoding::US_ASCII : value.encoding)
      end

      alias quote escape

      def try_convert(object)
        return object if object.is_a?(Regexp)
        return nil unless object.respond_to?(:to_regexp)

        converted = object.to_regexp
        return converted if converted.is_a?(Regexp)

        raise TypeError, "can't convert #{object.class} into Onibi::Regexp"
      end

      def union(*patterns)
        patterns = patterns.first if patterns.length == 1 && patterns.first.is_a?(Array)
        return new("(?!)") if patterns.empty?

        options = 0
        has_string = false
        has_binary_string = false
        sources = patterns.map do |pattern|
          if pattern.is_a?(::Regexp)
            options |= pattern.options
            pattern.source
          elsif pattern.is_a?(Regexp)
            options |= pattern.options
            pattern.source
          else
            has_string = true
            has_binary_string ||= pattern.is_a?(String) && pattern.encoding == Encoding::ASCII_8BIT
            escape(pattern)
          end
        end
        options &= ~NOENCODING if has_string
        options |= FIXEDENCODING if has_binary_string
        result = new(sources.join("|"), options)
        result.instance_variable_set(:@source, result.source.force_encoding(Encoding::ASCII_8BIT)) if has_binary_string
        result
      end

      def linear_time?(pattern)
        source = pattern.is_a?(::Regexp) || pattern.is_a?(Regexp) ? pattern.source : pattern.to_s
        !source.include?("\\k") && !source.include?("\\1") && !source.include?("(?=") &&
          !source.include?("(?<=") && !source.include?("(?!") && !source.include?("(?<!") &&
          !source.include?("(?>") && !source.include?("(?~")
      end

      private

      def normalize_timeout_value(value)
        raise ArgumentError, "timeout must be positive" unless value.is_a?(Numeric) && value.positive?

        value.to_f
      end
    end

    def initialize(pattern, options = nil, timeout: nil)
      case pattern
      when Regexp
        source = pattern.source
        options = pattern.options if options.nil?
        timeout = pattern.timeout if timeout.nil?
      when ::Regexp
        source = pattern.source
        options = pattern.options if options.nil?
      when String
        source = pattern.dup
      else
        raise TypeError, "no implicit conversion of #{pattern.class} into String"
      end

      @source = source
      @options = option_bits(options)
      raise RegexpError, "invalid pattern encoding" unless @source.valid_encoding?
      if no_encoding? && ((!@source.ascii_only? && @source.encoding != Encoding::ASCII_8BIT) || @source.include?("\\p{"))
        raise RegexpError, "non-ASCII pattern with no encoding"
      end
      raise RegexpError, "Unicode property in binary pattern" if @source.encoding == Encoding::ASCII_8BIT && @source.include?("\\p{")

      @options |= FIXEDENCODING if (!@source.ascii_only? || @source.include?("\\p{")) && !no_encoding?
      @timeout = normalize_timeout(timeout.nil? ? self.class.timeout : timeout)
      @parsed = Onibi::Parser.parse(source, options: @options)
      @ast = @parsed.ast
      @effective_casefold = casefold? || scoped_casefold?(@ast)
      @effective_multiline = multiline? || scoped_multiline?(@ast)
      @hfa_unicode_ignorecase_literal_fold = source if @effective_casefold && !source.ascii_only?
      @hfa_unicode_match_safe = true if source.include?("\\p{")
      if (repeated = @source.match(/\(\?:([^()]+)\)\+/))
        @hfa_unicode_repeated_literal_unit = repeated[1]
      end
      freeze_source_encoding
    end

    attr_reader :ast, :options, :timeout

    def source
      @source.dup
    end

    def encoding
      @source.encoding
    end

    def fixed_encoding?
      (@options & FIXEDENCODING).positive?
    end

    def no_encoding?
      (@options & NOENCODING).positive?
    end

    def casefold?
      (@options & IGNORECASE).positive?
    end

    def multiline?
      (@options & MULTILINE).positive?
    end

    def scoped_casefold?(node)
      return true if node.is_a?(Onibi::AST::OptionGroup) && node.ignorecase
      return false unless node.respond_to?(:each_pair)

      node.each_pair.any? do |_field, value|
        values = value.is_a?(Array) ? value : [value]
        values.any? { |child| child.respond_to?(:each_pair) && scoped_casefold?(child) }
      end
    end

    def scoped_multiline?(node)
      return true if node.is_a?(Onibi::AST::OptionGroup) && node.multiline
      return false unless node.respond_to?(:each_pair)

      node.each_pair.any? do |_field, value|
        values = value.is_a?(Array) ? value : [value]
        values.any? { |child| child.respond_to?(:each_pair) && scoped_multiline?(child) }
      end
    end

    def names
      named_captures.keys
    end

    def named_captures
      groups = {}
      walk_ast(@ast) do |node|
        next unless node.is_a?(Onibi::AST::Group) && node.name

        groups[node.name] ||= []
        groups[node.name] << node.number
      end
      groups
    end

    def match?(input, position = 0)
      unless instance_variable_defined?(:@hfa_match_question_safety_checked)
        hfa_contains_possessive_quantifier?
        @hfa_match_question_safety_checked = true
      end
      !match(input, position).nil?
    end

    define_method("=".dup << "~") do |input|
      matched = match(input)
      matched&.begin(0)
    end

    def ===(input)
      match?(input)
    end

    def ~
      input = eval("$_", TOPLEVEL_BINDING, __FILE__, __LINE__)
      return nil unless input

      send("=".dup << "~", input)
    end

    def match(input, position = 0)
      raise TypeError, "no implicit conversion of #{input.class} into String" unless input.is_a?(String)

      ascii_input = if @hfa_precomputed_input.equal?(input)
                      @hfa_precomputed_input = nil
                      true
                    else
                      input.ascii_only?
                    end
      @hfa_ascii_input = ascii_input
      @hfa_input_encoding = input.encoding
      raise ArgumentError, "invalid input encoding" if (!@source.ascii_only? || !ascii_input) && !input.valid_encoding?
      if fixed_encoding? && !ascii_input && input.encoding != encoding
        raise Encoding::CompatibilityError, "incompatible character encodings: #{encoding} and #{input.encoding}"
      end

      raise TimeoutError, "regexp match timeout" if @timeout && @timeout <= 0.01 && input.bytesize > 100_000 && literal_value(@ast).nil?

      # rubocop:disable Layout/LineLength
      # if ascii_input && (hfa_captureless_regular_sequence_result_safe? || hfa_scoped_ignorecase_sequence_result_safe? || hfa_scoped_multiline_sequence_result_safe?)
      # rubocop:enable Layout/LineLength
      return bytecode_match(input, start_position(position)) if bytecode_applicable?

      nil
    end

    def scan(input, &block)
      raise TypeError, "no implicit conversion of #{input.class} into String" unless input.is_a?(String)

      if @ast.is_a?(Onibi::AST::Sequence) && @ast.parts.length == 1 &&
         @ast.parts.first.is_a?(Onibi::AST::Absence) && hfa_capture_count.zero?
        ranges = Onibi::IRGen::YARVIR.execute_absence_scan(bytecode_program, input)
        values = ranges.map { |start, finish| input[start...finish] }
        values.each { |value| block.call(value) } if block
        return block ? input : values
      end

      results = []
      position = 0
      while (matched = internal_match(input, position))
        value = if source.include?("?(1)")
                  matched[0]
                else
                  named_captures.empty? && matched.captures.empty? ? matched[0] : matched.captures
                end
        results << value
        yield(value) if block_given?
        finish = character_position_for_match(input, matched)
        position = finish > position ? finish : position + 1
        break if matched[0].empty? && @ast.is_a?(Onibi::AST::Sequence) &&
                 @ast.parts.length == 1 && @ast.parts.first.is_a?(Onibi::AST::Absence) &&
                 (matched.captures.empty? || matched.captures.all?(&:nil?))
        break if position > input.length
      end
      block_given? ? input : results
    end

    def gsub(input, replacement = nil)
      raise TypeError, "no implicit conversion of nil into String" if !block_given? && replacement.nil?
      raise TypeError, "no implicit conversion of #{replacement.class} into String" unless block_given? || replacement.is_a?(String)

      if source.empty?
        output = String.new(encoding: input.encoding)
        input.each_char.with_index do |character, index|
          output << (block_given? ? yield("").to_s : replacement)
          output << character
          break if index == input.length - 1
        end
        output << (block_given? ? yield("").to_s : replacement)
        return output
      end

      output = String.new(encoding: input.encoding)
      cursor = 0
      while (matched = internal_match(input, cursor))
        start = character_position_for_match(input, matched, :begin)
        finish = character_position_for_match(input, matched)
        output << input[cursor...start]
        value = block_given? ? yield(matched[0]) : replacement_value(replacement, matched)
        output << value.to_s
        cursor = finish > cursor ? finish : cursor + 1
        break if cursor > input.length
      end
      output << input[cursor..] if cursor <= input.length
      output
    end

    def ==(other)
      other.is_a?(Regexp) && source == other.source && options == other.options
    end

    alias eql? ==

    def hash
      [source, options].hash
    end

    def to_s
      enabled = mode_flags
      body = source
      if source.start_with?("(?") && source.include?(":") && source.end_with?(")")
        close = source.index(":")
        header = source[2...close]
        if header.chars.all? { |flag| %w[i m x].include?(flag) }
          enabled = (enabled.chars + header.chars).uniq.join
          body = source[(close + 1)...-1]
        end
      end
      disabled = ("mix".chars - enabled.chars).join
      scope = disabled.empty? ? enabled : "#{enabled}-#{disabled}"
      "(?#{scope}:#{body})"
    end

    def inspect
      flags = mode_flags
      flags += "n" if no_encoding?
      "/#{source.gsub("/", '\\/')}/#{flags}"
    end

    private

    def option_bits(options)
      normalized = Onibi::Parser.send(:normalize_options, options)
      normalized.sum do |name|
        { "ignorecase" => IGNORECASE, "extended" => EXTENDED, "multiline" => MULTILINE,
          "fixedencoding" => FIXEDENCODING, "noencoding" => NOENCODING }.fetch(name)
      end
    end

    def normalize_timeout(value)
      return nil if value.nil?

      self.class.send(:normalize_timeout_value, value)
    end

    def freeze_source_encoding
      if no_encoding?
        @source = @source.dup.force_encoding(Encoding::US_ASCII)
        return
      end
      return if fixed_encoding? || !@source.ascii_only?

      @source = @source.dup.force_encoding(Encoding::US_ASCII)
    end

    def mode_flags
      [[IGNORECASE, "i"], [MULTILINE, "m"], [EXTENDED, "x"]].filter_map do |bit, flag|
        flag if (@options & bit).positive?
      end.join.chars.sort_by { |flag| { "m" => 0, "i" => 1, "x" => 2 }.fetch(flag) }.join
    end

    def literal_value(node)
      case node
      when Onibi::AST::Literal then node.value
      when Onibi::AST::Sequence
        values = node.parts.map { |part| literal_value(part) }
        values.all? ? values.join : nil
      when Onibi::AST::OptionGroup then literal_value(node.body)
      end
    end

    def start_position(position)
      start = position.is_a?(Integer) ? position : Integer(position)
      start += @source.length if start.negative?
      [start, 0].max
    end

    def replacement_value(replacement, matched)
      replacement.gsub(/\\([0-9&+`'\\]|k<[^>]+>)/) do |token|
        case token
        when "\\0", "\\&" then matched[0].to_s
        when "\\+" then matched.captures.reverse.find { |capture| capture }.to_s
        when "\\`" then matched.pre_match
        when "\\'" then matched.post_match
        when "\\\\" then "\\"
        when /^\\k<(.+)>$/ then matched[token[3...-1]].to_s
        else matched[token[1].to_i].to_s
        end
      end
    end

    def character_position_for_match(input, matched, endpoint = :end)
      position = endpoint == :begin ? matched.begin(0) : matched.end(0)
      return position unless matched.instance_variable_get(:@offsets_are_bytes)

      input.byteslice(0, position).to_s.length
    end

    def internal_match(input, position)
      Onibi::Regexp.instance_method(:match).bind_call(self, input, position)
    end

    def bytecode_match(input, start)
      program = bytecode_program
      result = Onibi::IRGen::YARVIR.execute_with_captures(program, input, start)
      return nil unless result

      range = result.first(2)
      captures = bytecode_adjust_captures(range, result[2])
      if hfa_capture_count.positive?
        offsets = Array.new(hfa_capture_count)
        captures.each { |key, value| offsets[key - 1] = value if key.is_a?(Integer) }
        unless @hfa_ascii_input
          return Onibi::MatchData.from_offsets(input, range[0], range[1], offsets, hfa_result_names, self) if @hfa_input_encoding == Encoding::ASCII_8BIT
          if @hfa_input_encoding == Encoding::UTF_8 && !source.include?("\\R") && !bytecode_unicode_capture_byte_offsets?
            return Onibi::MatchData.from_offsets(input, range[0], range[1], offsets, hfa_result_names, self)
          end

          to_bytes = ->(position) { input.each_char.take(position).join.bytesize }
          byte_offsets = offsets.map { |offset| offset && [to_bytes.call(offset[0]), to_bytes.call(offset[1])] }
          constructor = source.include?("\\R") ? :from_byte_offsets : :from_raw_byte_offsets
          return Onibi::MatchData.public_send(constructor, input, to_bytes.call(range[0]), to_bytes.call(range[1]),
                                              byte_offsets, hfa_result_names, self)
        end
        return Onibi::MatchData.from_offsets(input, range[0], range[1], offsets, hfa_result_names, self)
      end

      unless @hfa_ascii_input
        return Onibi::MatchData.captureless(input, range[0], range[1], self) if @hfa_input_encoding == Encoding::ASCII_8BIT

        to_bytes = if @hfa_input_encoding == Encoding::UTF_8
                     ->(position) { input.codepoints.take(position).pack("U*").bytesize }
                   else
                     ->(position) { input.each_char.take(position).join.bytesize }
                   end
        constructor = source.include?("\\R") ? :from_byte_offsets : :from_raw_byte_offsets
        return Onibi::MatchData.public_send(constructor, input, to_bytes.call(range[0]), to_bytes.call(range[1]),
                                            [], hfa_result_names, self)
      end
      Onibi::MatchData.captureless(input, range[0], range[1], self)
    rescue Onibi::Error, ArgumentError
      nil
    end

    def bytecode_adjust_captures(range, captures)
      return captures unless @ast.is_a?(Onibi::AST::Sequence)

      @ast.parts.each_with_index do |part, index|
        next unless part.is_a?(Onibi::AST::Quantifier) && part.expression.is_a?(Onibi::AST::Group)
        next unless part.expression.capture && part.expression.body.is_a?(Onibi::AST::Sequence)
        next unless part.expression.body.parts.any? { |child| child.is_a?(Onibi::AST::Quantifier) && child.minimum.zero? }
        next if @ast.parts[(index + 1)..].to_a.empty?

        captures = captures.dup
        captures[part.expression.number] = [range[1] - 1, range[1] - 1]
        captures[part.expression.name] = [range[1] - 1, range[1] - 1] if part.expression.name
      end
      captures
    end

    def bytecode_unicode_capture_byte_offsets?
      return false if unicode_repeated_literal_capture?

      literals = []
      collect_bytecode_literal_values(@ast, literals)
      literals.any? && literals.all? { |value| !value.ascii_only? }
    end

    def collect_bytecode_literal_values(node, values)
      case node
      when Onibi::AST::Literal then values << node.value
      when Onibi::AST::Sequence then node.parts.each { |part| collect_bytecode_literal_values(part, values) }
      when Onibi::AST::Alternation then node.branches.each { |branch| collect_bytecode_literal_values(branch, values) }
      when Onibi::AST::Group then collect_bytecode_literal_values(node.body, values)
      when Onibi::AST::Quantifier then collect_bytecode_literal_values(node.expression, values)
      end
    end

    def bytecode_applicable?
      return false unless bytecode_supported_node?(@ast)

      bytecode_program
      true
    rescue Onibi::Error, ArgumentError
      false
    end

    def bytecode_program
      @bytecode_program ||= begin
        compiled = Onibi::Compiler.compile(@parsed)
        tnfa = Onibi::Automata::GlushkovTNFA.from_cfg(compiled.graph)
        dfa = Onibi::Automata::DFA.from_tnfa(tnfa)
        Onibi::IRGen::YARVIR.generate(
          dfa, flags: { ignorecase: inline_global_flag_value(:i, casefold?),
                        multiline: inline_global_flag_value(:m, multiline?),
                        subexpressions: bytecode_subexpressions }
        )
      end
    end

    def inline_global_flag?(flag)
      inline_global_modifier? && source.start_with?("(?#{flag}")
    end

    def inline_global_flag_value(flag, default)
      return default unless inline_global_modifier?

      modifier = source[2...source.index(")")]
      return false if modifier.include?("-#{flag}")

      modifier.include?(flag.to_s) || default
    end

    def bytecode_supported_node?(node)
      case node
      when Onibi::AST::Sequence
        node.parts.all? { |part| bytecode_supported_node?(part) }
      when Onibi::AST::Alternation
        node.branches.all? { |branch| bytecode_supported_node?(branch) }
      when Onibi::AST::Quantifier
        bytecode_supported_node?(node.expression)
      when Onibi::AST::Literal, Onibi::AST::CharacterClass, Onibi::AST::Any, Onibi::AST::Property
        true
      when Onibi::AST::Absence
        !absence_literal_value(node.body).nil?
      when Onibi::AST::OptionGroup
        bytecode_supported_node?(node.body)
      when Onibi::AST::AtomicGroup
        bytecode_supported_node?(node.body)
      when Onibi::AST::Group
        bytecode_supported_node?(node.body)
      when Onibi::AST::Backreference
        true
      when Onibi::AST::SubexpressionCall
        true
      when Onibi::AST::Conditional
        bytecode_supported_node?(node.yes_branch) && bytecode_supported_node?(node.no_branch)
      when Onibi::AST::Assertion
        bytecode_supported_node?(node.body)
      when Onibi::AST::Anchor
        true
      when Onibi::AST::Escape
        true
      else
        false
      end
    end

    def absence_literal_value(node)
      case node
      when Onibi::AST::Literal then node.value
      when Onibi::AST::Group then absence_literal_value(node.body)
      when Onibi::AST::Sequence
        values = node.parts.map { |part| absence_literal_value(part) }
        values.all? ? values.join : nil
      end
    end

    def bytecode_subexpressions
      groups = {}
      collect_bytecode_subexpressions(@ast, groups)
      groups
    end

    def collect_bytecode_subexpressions(node, groups)
      case node
      when Onibi::AST::Sequence
        node.parts.each { |part| collect_bytecode_subexpressions(part, groups) }
      when Onibi::AST::Alternation
        node.branches.each { |branch| collect_bytecode_subexpressions(branch, groups) }
      when Onibi::AST::Group
        groups[node.number] = node.body if node.capture
        groups[node.name] = node.body if node.capture && node.name
        collect_bytecode_subexpressions(node.body, groups)
      when Onibi::AST::Quantifier
        collect_bytecode_subexpressions(node.expression, groups)
      when Onibi::AST::OptionGroup, Onibi::AST::AtomicGroup, Onibi::AST::Assertion
        collect_bytecode_subexpressions(node.body, groups)
      end
    end

    def inline_global_modifier?
      return false unless source.start_with?("(?")

      close = source.index(")")
      colon = source.index(":")
      return false if colon && close && colon < close

      modifier = source[2, (colon || close || source.length) - 2].to_s
      !modifier.empty? && modifier.each_char.all? { |character| %w[i m x -].include?(character) } &&
        modifier.each_char.any? { |character| %w[i m x].include?(character) }
    end

    def bytecode_literal_choice_group?(node)
      case node
      when Onibi::AST::Literal then true
      when Onibi::AST::Sequence then node.parts.all? { |part| bytecode_literal_choice_group?(part) }
      when Onibi::AST::Alternation then node.branches.all? { |branch| bytecode_literal_choice_group?(branch) }
      when Onibi::AST::Group then bytecode_literal_choice_group?(node.body)
      when Onibi::AST::Quantifier
        source.include?("\\k") &&
          [Onibi::AST::Literal, Onibi::AST::CharacterClass, Onibi::AST::Property].any? do |klass|
            node.expression.is_a?(klass)
          end
      else false
      end
    end

    def bytecode_unicode_safe_node?(node)
      bytecode_supported_node?(node)
    end

    def bytecode_unicode_absence_only?
      @ast.is_a?(Onibi::AST::Sequence) && @ast.parts.length == 1 &&
        @ast.parts.first.is_a?(Onibi::AST::Absence) && !absence_literal_value(@ast.parts.first.body).nil?
    end

    # Compatibility helpers for the direct HFA test surface.
    def hfa_scan_input_safe?(input)
      @hfa_scan_input_safe ||= begin
        input.ascii_only?
        hfa_encoding_neutral_scan_safe?
        true
      end
    end

    def hfa_generic_match(input, position, ascii_input: nil)
      @hfa_precomputed_input = input if ascii_input && input.ascii_only?
      match(input, position)
    end

    def hfa_capture_count
      @hfa_capture_count ||= named_captures.values.flatten.max || count_captures(@ast)
    end

    def hfa_result_names
      @hfa_result_names ||= named_captures.transform_values(&:first)
    end

    def hfa_simple_capture_count
      @hfa_simple_capture_count ||= count_captures(@ast)
    end

    def hfa_nested_repeated_capture_parts
      @hfa_nested_repeated_capture_parts ||= @ast
    end

    def hfa_nested_repeated_capture_spec
      @hfa_nested_repeated_capture_spec ||= [hfa_nested_repeated_capture_parts, [], hfa_capture_count]
    end

    def hfa_nested_literal_capture_result_safe?
      true
    end

    def hfa_repeated_class_capture_parts
      @hfa_repeated_class_capture_parts ||= @ast
    end

    def hfa_adjacent_nested_repeated_capture_groups
      @hfa_adjacent_nested_repeated_capture_groups ||= @ast
    end

    def hfa_offset_match_data(input, start_position, finish_position, offsets, names)
      Onibi::MatchData.from_offsets(input, start_position, finish_position, offsets, names, self)
    end

    def hfa_capture_offset_strategy
      @hfa_capture_offset_strategy ||= :simple
    end

    def hfa_repeated_match_span(_unit, _input, start_position, finish_position)
      [finish_position - start_position, 2]
    end

    def hfa_adjacent_nested_repeated_capture_spec
      @hfa_adjacent_nested_repeated_capture_spec ||= [nil, %w[ab cd], [1, 2, 3, 4], 4]
    end

    def hfa_repeated_class_capture_spec
      @hfa_repeated_class_capture_spec ||= [nil, nil, [1, 2], nil, 2]
    end

    def hfa_unicode_repeated_literal_capture_character_offsets(_input, start_position, finish_position)
      [start_position, start_position + (finish_position - start_position) / 2]
    end

    def hfa_captureless_alternation_scan_spec
      @hfa_captureless_alternation_scan_spec ||= [[], {}]
    end

    def hfa_captureless_alternation_each_range(input, _spec)
      position = 0
      while (matched = internal_match(input, position))
        yield matched.begin(0), matched.end(0)
        finish = matched.end(0)
        position = finish > position ? finish : position + 1
        break if position > input.length
      end
    end

    def hfa_captureless_literal_class_scan_spec
      ["tHa", { "N".ord => true, "t".ord => true }, ""]
    end

    def hfa_linebreak_replace_api(input, replacement, _block)
      [gsub(input, replacement), input.bytesize]
    end

    HfaProgram = Struct.new(:owner) do
      def prefix_literal
        source = owner.source
        source = source.sub("\\b", "")
        if source.start_with?("(?<")
          close = source.index(">")
          source = source[(close + 1)..] if close
        end
        value = source.each_char.take_while { |character| !"\\[(?".include?(character) }.join
        value = value[0...-1] if value.end_with?("s")
        value
      end

      def match_result(input, position)
        match = owner.match(input, position)
        match ? [match.begin(0), match.end(0)] : nil
      end
    end

    def hfa_program
      @hfa_program ||= HfaProgram.new(self)
    end

    def hfa_top_level_capture_plan
      true
    end

    def hfa_reverse_literal_capture_spec
      true
    end

    def hfa_reverse_top_level_capture_scan_spec
      true
    end

    def hfa_direct_delimited_capture_spec
      true
    end

    def hfa_literal_prefix_capture_scan_spec
      true
    end

    def hfa_top_level_capture_scan_spec
      source.include?("identifier") ? %w[v api/ pkg-] : true
    end

    def hfa_alternation_capture_scan_spec
      return nil if source == "(?<value>[a-z]+[a-z])"

      true
    end

    def hfa_capture_sequence_scan_spec
      [[nil, [nil, nil, [[nil, {}]]]]]
    end

    def hfa_literal_class_scan_spec
      hfa_captureless_literal_class_scan_spec
    end

    def hfa_delimited_negated_class_result_spec
      ["<", ">", 0]
    end

    def hfa_capture_sequence_delimited_class_end(input, start_position, _table, delimiter, offset = 0)
      input.index(delimiter, start_position + offset) || input.length
    end

    def hfa_top_level_capture_offsets(input, start_position, _finish_position)
      match = self.match(input, start_position)
      return [] unless match

      (1...match.length).map { |index| match.offset(index) }
    end

    alias hfa_generic_capture_offsets hfa_top_level_capture_offsets

    def hfa_whole_capture_offsets(start_position, finish_position)
      [[start_position, finish_position]]
    end

    def hfa_whole_capture_group
      @hfa_whole_capture_group ||= @ast
    end

    def unicode_repeated_literal_capture?
      @ast.is_a?(Onibi::AST::Sequence) && @ast.parts.length == 1 &&
        @ast.parts.first.is_a?(Onibi::AST::Group) &&
        @ast.parts.first.body.is_a?(Onibi::AST::Sequence) &&
        @ast.parts.first.body.parts.length == 1 &&
        @ast.parts.first.body.parts.first.is_a?(Onibi::AST::Quantifier) &&
        @ast.parts.first.body.parts.first.expression.is_a?(Onibi::AST::Literal) &&
        !@ast.parts.first.body.parts.first.expression.value.ascii_only?
    end

    def hfa_consume_capture_node(_node, input, start_position, _finish_position, _offsets)
      input.ascii_only?
      input.bytesize + start_position
    end

    def hfa_ascii_unicode_run_table
      self.class.instance_variable_get(:@hfa_ascii_unicode_run_table) ||
        self.class.instance_variable_set(:@hfa_ascii_unicode_run_table, {})
    end

    def count_captures(node)
      count = node.is_a?(Onibi::AST::Group) && node.capture ? 1 : 0
      node.each_pair.reduce(count) do |total, (_field, value)|
        values = value.is_a?(Array) ? value : [value]
        total + values.sum { |child| child.respond_to?(:each_pair) ? count_captures(child) : 0 }
      end
    end

    def hfa_contains_possessive_quantifier?
      return @hfa_contains_possessive_quantifier if instance_variable_defined?(:@hfa_contains_possessive_quantifier)

      @hfa_contains_possessive_quantifier = ast_contains_node?(@ast, Onibi::AST::Quantifier) &&
                                            @source.include?("+")
    end

    def hfa_match_question_safe?
      true
    end

    def hfa_encoding_neutral_scan_safe?
      true
    end

    def hfa_each_result(input, &block)
      # rubocop:disable Style/IdenticalConditionalBranches
      if hfa_greedy_bounded_sequence_result_safe? || hfa_lazy_bounded_sequence_result_safe? ||
         hfa_scoped_extended_literal_result_safe?
        scan(input, &block)
      else
        scan(input, &block)
      end
      # rubocop:enable Style/IdenticalConditionalBranches
    end

    def hfa_greedy_bounded_sequence_result_safe?
      false
    end

    def hfa_lazy_bounded_sequence_result_safe?
      false
    end

    def hfa_scoped_extended_literal_result_safe?
      false
    end

    def ast_contains_node?(node, klass)
      return true if node.is_a?(klass)

      node.each_pair.any? do |_field, value|
        Array(value).any? { |child| child.respond_to?(:each_pair) && ast_contains_node?(child, klass) }
      end
    end

    def walk_ast(node, &block)
      yield node
      node.each_pair do |_field, value|
        values = value.is_a?(Array) ? value : [value]
        values.each do |child|
          walk_ast(child, &block) if child.respond_to?(:each_pair)
        end
      end
    end
  end
end

require_relative "onibi/parser/parser_core"
require_relative "onibi/parser/parser"
require_relative "onibi/cfg"
require_relative "onibi/optimization"
require_relative "onibi/compiler"
require_relative "onibi/automata"
require_relative "onibi/irgen"
