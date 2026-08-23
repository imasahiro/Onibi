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

      def regexp_scope(pattern)
        enabled = [[::Regexp::IGNORECASE, "i"], [::Regexp::MULTILINE, "m"],
                   [::Regexp::EXTENDED, "x"]].filter_map do |bit, flag|
          flag if (pattern.options & bit).positive?
        end.join
        disabled = ("mix".chars - enabled.chars).join
        "(?#{enabled}-#{disabled}:#{pattern.source})"
      end

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

        return new(patterns.first.source, patterns.first.options) if
          patterns.length == 1 && (patterns.first.is_a?(::Regexp) || patterns.first.is_a?(Regexp))

        options = 0
        has_string = false
        has_binary_string = false
        sources = patterns.map do |pattern|
          if pattern.is_a?(::Regexp)
            options |= pattern.options & FIXEDENCODING
            regexp_scope(pattern)
          elsif pattern.is_a?(Regexp)
            options |= pattern.options & FIXEDENCODING
            regexp_scope(pattern)
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

      ascii_input = input.ascii_only?
      @ascii_input = ascii_input
      @input_encoding = input.encoding
      raise ArgumentError, "invalid input encoding" if (!@source.ascii_only? || !ascii_input) && !input.valid_encoding?
      if fixed_encoding? && !ascii_input && input.encoding != encoding
        raise Encoding::CompatibilityError, "incompatible character encodings: #{encoding} and #{input.encoding}"
      end

      raise TimeoutError, "regexp match timeout" if @timeout && @timeout <= 0.01 && input.bytesize > 100_000 && literal_value(@ast).nil?

      start = if bytecode_nullable?
                nullable_match_position(position, input.length)
              else
                start_position(position, input.length)
              end
      return nil unless start

      bytecode_match(input, start)
    end

    def scan(input, &block)
      raise TypeError, "no implicit conversion of #{input.class} into String" unless input.is_a?(String)

      results = []
      position = 0
      while position <= input.length && (matched = internal_match(input, position))
        value = if source.include?("?(1)")
                  matched[0]
                else
                  named_captures.empty? && matched.captures.empty? ? matched[0] : matched.captures
                end
        results << value
        yield(value) if block_given?
        match_start = character_position_for_match(input, matched, :begin)
        finish = character_position_for_match(input, matched)
        position = finish > match_start ? finish : match_start + 1
        break if position > input.length
      end
      block_given? ? input : results
    end

    def gsub(input, replacement = nil)
      raise TypeError, "no implicit conversion of nil into String" if !block_given? && replacement.nil?
      raise TypeError, "no implicit conversion of #{replacement.class} into String" unless block_given? || replacement.is_a?(String)

      output = String.new(encoding: input.encoding)
      cursor = 0
      search_position = 0
      while search_position <= input.length && (matched = internal_match(input, search_position))
        start = character_position_for_match(input, matched, :begin)
        finish = character_position_for_match(input, matched)
        output << input[cursor...start]
        value = block_given? ? yield(matched[0]) : replacement_value(replacement, matched)
        output << value.to_s
        if finish == start
          cursor = start
          search_position = start + 1
        else
          cursor = finish
          search_position = finish
        end
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
        return to_s_without_scope unless header.each_char.all? { |flag| %w[i m x -].include?(flag) }

        positive, negative = header.split("-", 2)
        enabled_flags = enabled.chars + positive.to_s.chars
        enabled_flags -= negative.to_s.chars
        enabled = ("mix".chars & enabled_flags).join
        body = source[(close + 1)...-1]
      end
      disabled = ("mix".chars - enabled.chars).join
      scope = disabled.empty? ? enabled : "#{enabled}-#{disabled}"
      "(?#{scope}:#{body})"
    end

    def to_s_without_scope
      enabled = mode_flags
      disabled = ("mix".chars - enabled.chars).join
      scope = disabled.empty? ? enabled : "#{enabled}-#{disabled}"
      "(?#{scope}:#{source})"
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

    def start_position(position, input_length)
      start = position.is_a?(Integer) ? position : Integer(position)
      start += input_length if start.negative?
      return nil if start.negative? || start > input_length

      start
    end

    def nullable_match_position(position, input_length)
      start = position.is_a?(Integer) ? position : Integer(position)
      start += input_length if start.negative?
      return nil if start.negative?

      [start, input_length].min
    end

    def bytecode_nullable?
      @bytecode_nullable ||= minimum_match_width(@ast).zero?
    end

    def minimum_match_width(node)
      case node
      when Onibi::AST::Literal then node.value.length
      when Onibi::AST::CharacterClass, Onibi::AST::Property, Onibi::AST::Any then 1
      when Onibi::AST::Escape then %i[word_boundary not_word_boundary start_match].include?(node.kind) ? 0 : 1
      when Onibi::AST::Anchor, Onibi::AST::Assertion, Onibi::AST::Absence then 0
      when Onibi::AST::Backreference, Onibi::AST::SubexpressionCall then 0
      when Onibi::AST::Sequence then node.parts.sum { |part| minimum_match_width(part) }
      when Onibi::AST::Alternation then node.branches.map { |branch| minimum_match_width(branch) }.min
      when Onibi::AST::Group, Onibi::AST::AtomicGroup then minimum_match_width(node.body)
      when Onibi::AST::OptionGroup then minimum_match_width(node.body)
      when Onibi::AST::Conditional
        [node.yes_branch, node.no_branch].compact.map { |branch| minimum_match_width(branch) }.min
      when Onibi::AST::Quantifier then minimum_match_width(node.expression) * node.minimum
      else 1
      end
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
        else matched.names.empty? ? matched[token[1].to_i].to_s : ""
        end
      end
    end

    def character_position_for_match(_input, matched, endpoint = :end)
      endpoint == :begin ? matched.begin(0) : matched.end(0)
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
      if capture_count.positive?
        offsets = Array.new(capture_count)
        captures.each do |key, value|
          next unless key.is_a?(Integer)

          index = named_captures.empty? ? key : public_capture_numbers.index(key)&.+(1)
          offsets[index - 1] = value if index
        end
        unless @ascii_input
          return Onibi::MatchData.from_offsets(input, range[0], range[1], offsets, result_names, self) if @input_encoding == Encoding::ASCII_8BIT
          if @input_encoding == Encoding::UTF_8 && !source.include?("\\R") && !bytecode_unicode_capture_byte_offsets?
            return Onibi::MatchData.from_offsets(input, range[0], range[1], offsets, result_names, self)
          end

          to_bytes = ->(position) { input.each_char.take(position).join.bytesize }
          byte_offsets = offsets.map { |offset| offset && [to_bytes.call(offset[0]), to_bytes.call(offset[1])] }
          return Onibi::MatchData.from_byte_offsets(input, to_bytes.call(range[0]), to_bytes.call(range[1]),
                                                    byte_offsets, result_names, self)
        end
        return Onibi::MatchData.from_offsets(input, range[0], range[1], offsets, result_names, self)
      end

      unless @ascii_input
        return Onibi::MatchData.captureless(input, range[0], range[1], self) if @input_encoding == Encoding::ASCII_8BIT

        to_bytes = if @input_encoding == Encoding::UTF_8
                     ->(position) { input.codepoints.take(position).pack("U*").bytesize }
                   else
                     ->(position) { input.each_char.take(position).join.bytesize }
                   end
        return Onibi::MatchData.from_byte_offsets(input, to_bytes.call(range[0]), to_bytes.call(range[1]),
                                                  [], result_names, self)
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

    def bytecode_program
      @bytecode_program ||= begin
        compiled = Onibi::Compiler.compile(@parsed)
        tnfa = Onibi::Automata::GlushkovTNFA.from_cfg(compiled.graph)
        dfa = Onibi::Automata::DFA.from_tnfa(tnfa)
        Onibi::IRGen::YARVIR.generate(
          dfa, flags: { ignorecase: inline_global_flag_value(:i, casefold?),
                        multiline: inline_global_flag_value(:m, multiline?),
                        subexpressions: bytecode_subexpressions,
                        semantic_root: Onibi::IRGen::YARVIR::SemanticBytecode.compile(@ast) }
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

    def bytecode_subexpressions
      groups = {}
      collect_bytecode_subexpressions(@ast, groups)
      groups.transform_values { |body| Onibi::IRGen::YARVIR::SemanticBytecode.compile(body) }
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

    def unicode_repeated_literal_capture?
      @ast.is_a?(Onibi::AST::Sequence) && @ast.parts.length == 1 &&
        @ast.parts.first.is_a?(Onibi::AST::Group) &&
        @ast.parts.first.body.is_a?(Onibi::AST::Sequence) &&
        @ast.parts.first.body.parts.length == 1 &&
        @ast.parts.first.body.parts.first.is_a?(Onibi::AST::Quantifier) &&
        @ast.parts.first.body.parts.first.expression.is_a?(Onibi::AST::Literal) &&
        !@ast.parts.first.body.parts.first.expression.value.ascii_only?
    end

    def capture_count
      @capture_count ||= begin
        return public_capture_numbers.length unless named_captures.empty?

        count = 0
        walk_ast(@ast) { |node| count += 1 if node.is_a?(Onibi::AST::Group) && node.capture }
        count
      end
    end

    def result_names
      @result_names ||= named_captures.transform_values do |indices|
        indices.map { |index| public_capture_numbers.index(index) + 1 }
      end
    end

    def public_capture_numbers
      @public_capture_numbers ||= begin
        numbers = []
        walk_ast(@ast) do |node|
          numbers << node.number if node.is_a?(Onibi::AST::Group) && node.capture && node.name
        end
        numbers
      end
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
