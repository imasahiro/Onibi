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
require_relative "onibi/class_predicates_validation"
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
    LAST_MATCH_KEY = :onibi_regexp_last_match
    LAST_MATCH_UNSET = Object.new.freeze

    class << self
      ESCAPE_REPLACEMENTS = {
        9 => "\\t",
        10 => "\\n",
        11 => "\\v",
        12 => "\\f",
        13 => "\\r"
      }.freeze
      ESCAPE_METACHARACTERS = "\\[]{}().*+?^$| #-"
      ESCAPE_METACHARACTER_CODES = ESCAPE_METACHARACTERS.bytes.freeze

      def compile(pattern, options = nil, timeout: nil)
        new(pattern, options, timeout: timeout)
      end

      def timeout=(value)
        @timeout = value.nil? ? nil : normalize_timeout_value(value)
      end

      attr_reader :timeout

      def last_match(index = LAST_MATCH_UNSET)
        matched = Thread.current[LAST_MATCH_KEY]
        return matched if index.equal?(LAST_MATCH_UNSET)

        matched&.[](index)
      end

      def escape(string)
        value = if string.is_a?(String)
                  string
                elsif string.is_a?(Symbol)
                  string.to_s
                elsif string.respond_to?(:to_str)
                  converted = string.to_str
                  unless converted.is_a?(String)
                    raise TypeError,
                          "can't convert #{string.class} to String (#{string.class}#to_str gives #{converted.class})"
                  end

                  converted
                else
                  type = case string
                         when nil then "nil"
                         when true then "true"
                         when false then "false"
                         else string.class
                         end
                  raise TypeError, "no implicit conversion of #{type} into String"
                end
        value = String.new(value)
        escaped = value.each_char.map do |character|
          replacement = ESCAPE_REPLACEMENTS[character.ord]
          replacement ||= "\\#{character.encode(Encoding::US_ASCII)}" if character.ord < 128 && ESCAPE_METACHARACTER_CODES.include?(character.ord)
          (replacement || character).encode(value.encoding)
        end.join
        escaped.force_encoding(escaped.ascii_only? ? Encoding::US_ASCII : value.encoding)
      end

      alias quote escape

      def regexp_scope(pattern)
        native = pattern.is_a?(::Regexp)
        pattern_options = native ? ::Regexp.instance_method(:options).bind_call(pattern) : pattern.options
        pattern_source = native ? ::Regexp.instance_method(:source).bind_call(pattern) : pattern.source
        enabled = [[::Regexp::IGNORECASE, "i"], [::Regexp::MULTILINE, "m"],
                   [::Regexp::EXTENDED, "x"]].filter_map do |bit, flag|
          flag if (pattern_options & bit).positive?
        end.join
        disabled = ("mix".chars - enabled.chars).join
        prefix = "(?#{enabled}-#{disabled}:".encode(pattern_source.encoding)
        suffix = ")".encode(pattern_source.encoding)
        prefix + pattern_source + suffix
      end

      def try_convert(object)
        return object if object.is_a?(Regexp) || object.is_a?(::Regexp)
        return nil unless object.respond_to?(:to_regexp)

        converted = object.to_regexp
        return converted if converted.is_a?(Regexp)

        raise TypeError, "can't convert #{object.class} into Onibi::Regexp"
      end

      def union(*patterns)
        patterns = Array.instance_method(:to_a).bind_call(patterns.first) if patterns.length == 1 && patterns.first.is_a?(Array)
        return new("(?!)") if patterns.empty?

        raise TypeError, "no implicit conversion of Symbol into String" if patterns.length > 1 && patterns.any? { |pattern| pattern.is_a?(Symbol) }

        if patterns.length == 1 && (patterns.first.is_a?(::Regexp) || patterns.first.is_a?(Regexp))
          native = patterns.first.is_a?(::Regexp)
          source = native ? ::Regexp.instance_method(:source).bind_call(patterns.first) : patterns.first.source
          options = native ? ::Regexp.instance_method(:options).bind_call(patterns.first) : patterns.first.options
          return new(source, options)
        end

        options = 0
        has_string = false
        has_binary_string = false
        has_non_ascii_source = false
        sources = patterns.map do |pattern|
          if pattern.is_a?(::Regexp)
            native_options = ::Regexp.instance_method(:options).bind_call(pattern)
            native_source = ::Regexp.instance_method(:source).bind_call(pattern)
            options |= native_options & FIXEDENCODING
            has_non_ascii_source ||= !native_source.ascii_only?
            regexp_scope(pattern)
          elsif pattern.is_a?(Regexp)
            options |= pattern.options & FIXEDENCODING
            has_non_ascii_source ||= !pattern.source.ascii_only?
            regexp_scope(pattern)
          else
            pattern = String.new(pattern) if pattern.is_a?(String)
            has_string = true
            has_binary_string ||= pattern.is_a?(String) && pattern.encoding == Encoding::ASCII_8BIT
            has_non_ascii_source ||= pattern.is_a?(String) && !pattern.ascii_only?
            escape(pattern)
          end
        end
        options &= ~NOENCODING if has_string
        options |= FIXEDENCODING if has_binary_string && has_non_ascii_source
        new(join_union_sources(sources), options)
      end

      def linear_time?(pattern)
        regexp = if pattern.is_a?(::Regexp) || pattern.is_a?(Regexp)
                   native = pattern.is_a?(::Regexp)
                   source = native ? ::Regexp.instance_method(:source).bind_call(pattern) : pattern.source
                   options = native ? ::Regexp.instance_method(:options).bind_call(pattern) : pattern.options
                   new(source, options)
                 else
                   new(pattern)
                 end
        linear_time_ast?(regexp.ast)
      end

      def linear_time_ast?(node)
        case node
        when Onibi::AST::Backreference, Onibi::AST::SubexpressionCall, Onibi::AST::Absence,
             Onibi::AST::Conditional
          false
        when Onibi::AST::Sequence
          node.parts.all? { |part| linear_time_ast?(part) }
        when Onibi::AST::Alternation
          node.branches.all? { |branch| linear_time_ast?(branch) }
        when Onibi::AST::Group, Onibi::AST::AtomicGroup, Onibi::AST::OptionGroup,
             Onibi::AST::Quantifier, Onibi::AST::Assertion
          linear_time_ast?(node.respond_to?(:body) ? node.body : node.expression)
        else
          true
        end
      end

      private

      def join_union_sources(sources)
        non_ascii_compatible = sources.filter_map do |source|
          source.encoding unless source.encoding.ascii_compatible?
        end.uniq
        encoding = non_ascii_compatible.first
        return sources.join("|") unless encoding

        raise ArgumentError, "ASCII incompatible encoding: #{encoding.name}" if sources.any? { |source| source.encoding != encoding }

        separator = "|".encode(encoding)
        sources.join(separator)
      end

      def normalize_timeout_value(value)
        unless value.is_a?(Numeric)
          type = case value
                 when String then "string"
                 when true then "true"
                 when false then "false"
                 end
          raise TypeError, "no implicit conversion to float from #{type}" if type

          raise TypeError, "can't convert #{value.class} into Float"
        end
        converted = value.to_f
        return nil if converted.nan?
        return (2**64) / 1_000_000_000.0 if converted.infinite? == 1

        raise ArgumentError, "invalid timeout: #{value}" unless converted.positive?

        converted
      end
    end

    def initialize(pattern, options = nil, timeout: nil)
      case pattern
      when Regexp
        source = pattern.source
        options = pattern.options if options.nil?
        timeout = pattern.timeout if timeout.nil?
      when ::Regexp
        source = ::Regexp.instance_method(:source).bind_call(pattern)
        options = ::Regexp.instance_method(:options).bind_call(pattern) if options.nil?
      when String
        source = pattern.dup
      else
        source = String.try_convert(pattern)
        raise TypeError, "no implicit conversion of #{pattern.class} into String" unless source
      end

      # Compile from a plain String. MRI's regexp compiler reads the string
      # payload and encoding directly; String subclass overrides must not
      # affect lexer or parser input.
      source = String.new(source)
      @source = source
      unicode_escape = @source.valid_encoding? && non_ascii_unicode_escape_pattern?
      source_encoding = @source.encoding
      @source = @source.dup.force_encoding(Encoding::UTF_8) if unicode_escape
      @options = option_bits(options)
      raise RegexpError, "invalid pattern encoding" unless @source.valid_encoding?
      raise RegexpError, "incompatible character encoding" if unicode_escape &&
                                                              source_encoding != Encoding::UTF_8 && fixed_encoding?
      if no_encoding? && ((!@source.ascii_only? && @source.encoding != Encoding::ASCII_8BIT) ||
                          non_ascii_unicode_escape_pattern?)
        raise RegexpError, "non-ASCII pattern with no encoding"
      end

      if no_encoding? && property_names.any?
        unless property_names.all? { |name| Onibi::UnicodeProperties.valid_for_encoding?(name, Encoding::US_ASCII) }
          raise RegexpError, "non-ASCII pattern with no encoding"
        end

        @options |= FIXEDENCODING
      end
      if @source.encoding == Encoding::ASCII_8BIT && property_names.any? &&
         !property_names.all? { |name| Onibi::UnicodeProperties.valid_for_encoding?(name, Encoding::US_ASCII) }
        invalid_name = property_names.find do |name|
          !Onibi::UnicodeProperties.valid_for_encoding?(name, Encoding::US_ASCII)
        end
        raise RegexpError, "invalid character property name {#{invalid_name}}: /#{@source}/"
      end

      validate_property_encoding!

      @options |= FIXEDENCODING if (!@source.ascii_only? || property_names.any?) && !no_encoding?
      @options |= FIXEDENCODING if non_ascii_escape_pattern? &&
                                   (no_encoding? || @source.encoding != Encoding::US_ASCII)
      @options |= FIXEDENCODING if non_ascii_unicode_escape_pattern?
      @timeout = normalize_timeout(timeout.nil? ? self.class.timeout : timeout)
      # The parser consumes Unicode scalar text. Keep the original pattern
      # encoding on the regexp object, but compile a UTF-8 view for the AST.
      @parsed = Onibi::Parser.parse(analysis_source, options: @options)
      @ast = Onibi::Compiler.normalize_numeric_escapes(@parsed.ast)
      Onibi::Compiler.validate(@ast)
      validate_subexpression_calls!
      validate_backreferences!
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

    def property_names
      @property_names ||= analysis_source.scan(/\\[pP]\{([^}]+)\}/).flatten.map do |name|
        Onibi::UnicodeProperties.normalize_name(name)
      end
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
      return {} if raw_named_captures.empty?

      raw_named_captures.transform_values do |indices|
        indices.map { |index| public_capture_numbers.index(index) + 1 }
      end
    end

    # The VM uses parser capture numbers. MRI uses a separate public number
    # space when a pattern has named captures: unnamed groups are hidden.
    def raw_named_captures
      groups = {}
      walk_ast(@ast) do |node|
        next unless node.is_a?(Onibi::AST::Group) && node.name

        groups[node.name] ||= []
        groups[node.name] << node.number
      end
      groups
    end

    def match?(input, position = 0)
      requested_position = normalize_match_position(position)
      matched = match_without_last_match(input, requested_position)
      return false unless matched
      return false if requested_position >= 0 && requested_position > match_input_length(input)

      true
    end

    define_method("=".dup << "~") do |input|
      matched = match(input)
      matched&.begin(0)
    end

    def ===(input)
      !match(input).nil?
    rescue TypeError
      Thread.current[LAST_MATCH_KEY] = nil
      false
    end

    def ~
      input = eval("$_", TOPLEVEL_BINDING, __FILE__, __LINE__)
      unless input
        Thread.current[LAST_MATCH_KEY] = nil
        return nil
      end
      unless input.is_a?(String)
        Thread.current[LAST_MATCH_KEY] = nil
        return nil
      end

      send("=".dup << "~", input)
    end

    def match(input, position = 0)
      result = match_without_last_match(input, position)
      Thread.current[LAST_MATCH_KEY] = result if result.is_a?(Onibi::MatchData)
      Thread.current[LAST_MATCH_KEY] = nil unless result.is_a?(Onibi::MatchData)
      block_given? && result ? yield(result) : result
    end

    def match_without_last_match(input, position = 0)
      requested_position = normalize_match_position(position)
      return nil if input.nil?

      input = input.to_s if input.is_a?(Symbol)

      unless input.is_a?(String)
        original_input = input
        input = String.try_convert(original_input)
        unless input
          type = case original_input
                 when nil then "nil"
                 when true then "true"
                 when false then "false"
                 else original_input.class
                 end
          raise TypeError, "no implicit conversion of #{type} into String"
        end
      end

      program = bytecode_program

      string_encoding = String.instance_method(:encoding).bind_call(input)
      ascii_input = String.instance_method(:ascii_only?).bind_call(input)
      @ascii_input = ascii_input
      @input_encoding = string_encoding
      input_length = String.instance_method(:length).bind_call(input)
      return nil if requested_position.negative? && (requested_position + input_length).negative?

      input_valid = String.instance_method(:valid_encoding?).bind_call(input)
      raise ArgumentError, "invalid byte sequence in #{string_encoding.name}" if (!@source.ascii_only? || !ascii_input) && !input_valid

      if program.flags[:binary_escape] && !ascii_input && string_encoding != Encoding::ASCII_8BIT &&
         !(@source.encoding == Encoding::US_ASCII && !no_encoding? &&
           string_encoding == Encoding::ISO_8859_1)
        if @source.encoding == Encoding::US_ASCII && !no_encoding? &&
           [Encoding::UTF_8, Encoding::EUC_JP, Encoding::Windows_31J].include?(string_encoding)
          raise ArgumentError, "regexp preprocess failed: too short escaped multibyte character"
        end

        raise_incompatible_encoding(input)
      end
      raise_incompatible_encoding(input) if fixed_encoding? && !ascii_input && string_encoding != encoding
      raise_incompatible_encoding(input) if !encoding.ascii_compatible? && string_encoding != encoding
      # MRI does not allow an ASCII-compatible regexp to run on a
      # non-ASCII-compatible string. Such strings use a code-unit width that
      # the regexp encoding must declare explicitly (UTF-16 or UTF-32).
      raise_incompatible_encoding(input) if !string_encoding.ascii_compatible? && string_encoding != encoding

      input_bytesize = String.instance_method(:bytesize).bind_call(input)
      raise TimeoutError, "regexp match timeout" if @timeout && @timeout <= 0.01 && input_bytesize > 100_000 && !program.flags[:literal_only]

      start = if program.flags[:nullable]
                nullable_match_position(requested_position, input_length)
              else
                start_position(requested_position, input_length)
              end
      return nil unless start

      matched = bytecode_match(input, start, program)
      matched && block_given? ? yield(matched) : matched
    end

    private :match_without_last_match

    def scan(input, &block)
      raise TypeError, "no implicit conversion of #{input.class} into String" unless input.is_a?(String)

      results = []
      position = 0
      input_length = String.instance_method(:length).bind_call(input)
      while position <= input_length && (matched = internal_match(input, position))
        value = named_captures.empty? && matched.captures.empty? ? matched[0] : matched.captures
        results << value
        yield(value) if block_given?
        match_start = character_position_for_match(input, matched, :begin)
        finish = character_position_for_match(input, matched)
        position = finish > match_start ? finish : match_start + 1
        break if position > input_length
      end
      block_given? ? input : results
    end

    def gsub(input, replacement = nil)
      raise TypeError, "no implicit conversion of nil into String" if !block_given? && replacement.nil?
      raise TypeError, "no implicit conversion of #{replacement.class} into String" unless block_given? || replacement.is_a?(String)

      input_length = String.instance_method(:length).bind_call(input)
      output = String.new(encoding: String.instance_method(:encoding).bind_call(input))
      cursor = 0
      search_position = 0
      while search_position <= input_length && (matched = internal_match(input, search_position))
        start = character_position_for_match(input, matched, :begin)
        finish = character_position_for_match(input, matched)
        output << String.instance_method(:[]).bind_call(input, cursor...start)
        value = block_given? ? yield(matched[0]) : replacement_value(replacement, matched)
        output << if value.is_a?(String)
                    String.instance_method(:to_s).bind_call(value)
                  else
                    value.to_s
                  end
        if finish == start
          cursor = start
          search_position = start + 1
        else
          cursor = finish
          search_position = finish
        end
        break if cursor > input_length
      end
      output << String.instance_method(:[]).bind_call(input, cursor..) if cursor <= input_length
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
      display_source = source_for_display
      body = display_source.gsub("/", '\\/')
      if single_inline_scope?
        close = display_source.index(":")
        header = display_source[2...close]
        return to_s_without_scope unless header.each_char.all? { |flag| %w[i m x -].include?(flag) }

        positive, negative = header.split("-", 2)
        enabled_flags = enabled.chars + positive.to_s.chars
        enabled_flags -= negative.to_s.chars
        enabled = ("mix".chars & enabled_flags).join
        body = display_source[(close + 1)...-1].gsub("/", '\\/')
      end
      disabled = ("mix".chars - enabled.chars).join
      scope = disabled.empty? ? enabled : "#{enabled}-#{disabled}"
      rendered = "(?#{scope}:#{body})"
      encoding.ascii_compatible? ? rendered : rendered.encode(encoding)
    end

    def to_s_without_scope
      enabled = mode_flags
      disabled = ("mix".chars - enabled.chars).join
      scope = disabled.empty? ? enabled : "#{enabled}-#{disabled}"
      rendered = "(?#{scope}:#{source_for_display.gsub("/", '\\/')})"
      encoding.ascii_compatible? ? rendered : rendered.encode(encoding)
    end

    def inspect
      flags = mode_flags
      flags += "n" if no_encoding?
      "/#{inspect_source}/#{flags}"
    end

    private

    def source_for_display
      @source.encoding.ascii_compatible? ? source : source.encode(Encoding::UTF_8)
    end

    def inspect_source
      return inspect_non_ascii_compatible_source unless @source.encoding.ascii_compatible?

      if @source.encoding == Encoding::ASCII_8BIT
        return @source.bytes.map do |byte|
          if byte == 0x2f
            "\\/"
          else
            byte.between?(0x09, 0x7e) ? byte.chr : format("\\x%02X", byte)
          end
        end.join
      end

      source_for_display.each_char.map do |character|
        if [Encoding::UTF_8, Encoding::US_ASCII].include?(@source.encoding)
          next character == "/" ? "\\/" : character
        end

        if @source.encoding.ascii_compatible? && character.ord < 128
          next character == "/" ? "\\/" : character
        end

        codepoint = character.codepoints.first
        next format("\\x{%X}", codepoint) if @source.encoding.ascii_compatible?

        if codepoint < 128
          character == "/" ? "\\/" : character
        elsif codepoint <= 0xffff
          format("\\u%04X", codepoint)
        else
          format("\\u{%X}", codepoint)
        end
      end.join
    end

    def inspect_non_ascii_compatible_source
      bytes = @source.each_char.flat_map do |character|
        if character.ord < 128
          prefix = character == "/" ? "\\/" : character
          prefix.bytes
        elsif character.ord <= 0xffff
          format("\\u%04X", character.ord).bytes
        else
          format("\\u{%X}", character.ord).bytes
        end
      end
      bytes.pack("C*").force_encoding(Encoding::US_ASCII)
    end

    def single_inline_scope?
      display_source = source_for_display
      return false unless display_source.start_with?("(?") && display_source.include?(":") && display_source.end_with?(")")

      depth = 0
      escaped = false
      in_class = false
      display_source.each_char.with_index do |character, index|
        if escaped
          escaped = false
          next
        end
        if character == "\\"
          escaped = true
          next
        end
        if character == "["
          in_class = true
          next
        end
        in_class = false if character == "]"
        next if in_class

        depth += 1 if character == "("
        next unless character == ")"

        depth -= 1
        return false if depth.zero? && index != source.length - 1
      end
      depth.zero?
    end

    def raise_incompatible_encoding(input)
      pattern_encoding = encoding == Encoding::ASCII_8BIT ? "BINARY (ASCII-8BIT)" : encoding.name
      input_encoding_value = String.instance_method(:encoding).bind_call(input)
      input_encoding = input_encoding_value == Encoding::ASCII_8BIT ? "BINARY (ASCII-8BIT)" : input_encoding_value.name
      raise Encoding::CompatibilityError,
            "incompatible encoding regexp match (#{pattern_encoding} regexp with #{input_encoding} string)"
    end

    def option_bits(options)
      return IGNORECASE if options.is_a?(Symbol)

      unless options.nil? || options == false || options == true ||
             options.is_a?(Integer) || options.is_a?(String) || options.is_a?(Array)
        return IGNORECASE
      end

      normalized = Onibi::Parser.send(:normalize_options, options)
      normalized.sum do |name|
        { "ignorecase" => IGNORECASE, "extended" => EXTENDED, "multiline" => MULTILINE,
          "fixedencoding" => FIXEDENCODING, "noencoding" => NOENCODING }.fetch(name)
      end
    end

    def validate_property_encoding!
      analysis_source.scan(/\\[pP]\{([^}]+)\}/).each do |(name)|
        next if Onibi::UnicodeProperties.valid_for_encoding?(name, @source.encoding)

        raise RegexpError, "Unicode property is not supported by #{encoding_name_for_property}"
      end
    end

    def encoding_name_for_property
      @source.encoding.name
    end

    def normalize_timeout(value)
      return nil if value.nil?

      self.class.send(:normalize_timeout_value, value)
    end

    def freeze_source_encoding
      if no_encoding? && fixed_encoding?
        @source = @source.dup.force_encoding(Encoding::ASCII_8BIT)
        return
      end
      if no_encoding?
        @source = @source.dup.force_encoding(Encoding::US_ASCII)
        return
      end
      return unless @source.encoding.ascii_compatible?
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

    def normalize_match_position(position)
      return position if position.is_a?(Integer)

      if position.is_a?(Float)
        begin
          return Integer(position)
        rescue FloatDomainError
          value = if position.infinite?
                    position.positive? ? "Inf" : "-Inf"
                  else
                    "NaN"
                  end
          raise RangeError, "float #{value} out of range of integer"
        end
      end
      if position.respond_to?(:to_int)
        converted = position.to_int
        return converted if converted.is_a?(Integer)

        raise TypeError,
              "can't convert #{position.class} to Integer (#{position.class}#to_int gives #{converted.class})"
      end

      raise TypeError, "no implicit conversion from nil to integer" if position.nil?

      type = case position
             when true then "true"
             when false then "false"
             else position.class
             end
      raise TypeError, "no implicit conversion of #{type} into Integer"
    end

    def match_input_length(input)
      return String.instance_method(:length).bind_call(input) if input.is_a?(String)
      return 0 if input.nil? || input.is_a?(Symbol)

      converted = String.try_convert(input)
      String.instance_method(:length).bind_call(converted)
    end

    def nullable_match_position(position, input_length)
      start = position.is_a?(Integer) ? position : Integer(position)
      start += input_length if start.negative?
      return nil if start.negative?
      return nil if input_length.zero? && start.positive? && !nullable_position_clamp?(input_length)
      return start_position(position, input_length) unless nullable_position_clamp?(input_length)

      [start, input_length].min
    end

    def nullable_position_clamp?(_input_length)
      # MRI runs a nullable bytecode at the input end when the requested
      # position is beyond the input. The bytecode decides if that position
      # is valid; anchors and assertions must not be classified here.
      true
    end

    def bytecode_nullable?
      bytecode_program.flags[:nullable]
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
      String.instance_method(:gsub).bind_call(replacement, /\\([0-9&+`'\\]|k<[^>]+>)/) do |token|
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

    def bytecode_match(input, start, program = bytecode_program)
      byte_input = @input_encoding == Encoding::ASCII_8BIT ||
                   (program.flags[:binary_escape] && @input_encoding == Encoding::ISO_8859_1)
      input_view = Onibi::InputView.new(input, byte_mode: byte_input)
      result = Onibi::IRGen::YARVIR.execute_with_captures(program, input, start, input_view: input_view)
      return nil unless result

      range = result.first(2)
      captures = result[2]
      if capture_count.positive?
        offsets = Array.new(capture_count)
        captures.each do |key, value|
          next unless key.is_a?(Integer)

          index = named_captures.empty? ? key : public_capture_numbers.index(key)&.+(1)
          offsets[index - 1] = value if index
        end
        unless @ascii_input
          return Onibi::MatchData.from_offsets(input, range[0], range[1], offsets, result_names, self) if @input_encoding == Encoding::ASCII_8BIT
          if @input_encoding == Encoding::UTF_8 && !program.flags[:linebreak_escape] && !program.flags[:unicode_capture_byte_offsets]
            return Onibi::MatchData.from_offsets(input, range[0], range[1], offsets, result_names, self)
          end

          byte_positions = character_byte_positions(input, input_view)
          to_bytes = ->(position) { byte_positions.fetch(position) }
          byte_offsets = offsets.map { |offset| offset && [to_bytes.call(offset[0]), to_bytes.call(offset[1])] }
          return Onibi::MatchData.from_byte_offsets(input, to_bytes.call(range[0]), to_bytes.call(range[1]),
                                                    byte_offsets, result_names, self)
        end
        return Onibi::MatchData.from_offsets(input, range[0], range[1], offsets, result_names, self)
      end

      unless @ascii_input
        return Onibi::MatchData.captureless(input, range[0], range[1], self) if @input_encoding == Encoding::ASCII_8BIT

        byte_positions = character_byte_positions(input, input_view)
        to_bytes = ->(position) { byte_positions.fetch(position) }
        return Onibi::MatchData.from_byte_offsets(input, to_bytes.call(range[0]), to_bytes.call(range[1]),
                                                  [], result_names, self)
      end
      Onibi::MatchData.captureless(input, range[0], range[1], self)
    rescue Onibi::Error, ArgumentError
      nil
    end

    # The VM cursor is a character index. Build the byte boundary table once
    # when MatchData needs byte offsets. MRI keeps these boundaries in its
    # encoding-aware matcher instead of rescanning the prefix for every
    # capture.
    def character_byte_positions(input, input_view = nil)
      (input_view || Onibi::InputView.new(input)).byte_boundaries
    end

    def bytecode_program
      @bytecode_program ||= begin
        compiled = Onibi::Compiler.compile(@ast, options: @options, encoding: @source.encoding)
        tnfa = Onibi::Automata::GlushkovTNFA.from_cfg(compiled.graph)
        dfa = Onibi::Automata::DFA.from_tnfa(tnfa)
        semantic_root = Onibi::IRGen::YARVIR::SemanticBytecode.compile(@ast)
        full_casefold = Onibi::IRGen::YARVIR::SemanticBytecode.full_casefold?(semantic_root)
        unicode_capture_byte_offsets =
          Onibi::IRGen::YARVIR::SemanticBytecode.unicode_capture_byte_offsets?(semantic_root)
        Onibi::IRGen::YARVIR.generate(
          dfa, flags: { encoding: @source.encoding,
                        ignorecase: inline_global_flag_value(:i, casefold?),
                        full_casefold: full_casefold,
                        multiline: inline_global_flag_value(:m, multiline?),
                        subexpressions: bytecode_subexpressions,
                        named_capture_numbers: raw_named_captures,
                        unicode_capture_byte_offsets: unicode_capture_byte_offsets,
                        binary_escape: binary_escape_pattern?,
                        linebreak_escape: analysis_source.include?("\\R"),
                        nullable: minimum_match_width(@ast).zero?,
                        literal_only: !literal_value(@ast).nil?,
                        semantic_root: semantic_root }
        )
      end
    end

    def inline_global_flag?(flag)
      inline_global_modifier? && analysis_source.start_with?("(?#{flag}")
    end

    def binary_escape_pattern?
      return false unless @source.ascii_only? && (no_encoding? || @source.encoding == Encoding::US_ASCII)

      non_ascii_escape_pattern?
    end

    def non_ascii_escape_pattern?
      analysis_source.scan(/\\x([0-9a-fA-F]{2})/).any? { |digits| digits.first.to_i(16) > 0x7f } ||
        analysis_source.scan(/\\([0-7]{3})/).any? { |digits| digits.first.to_i(8) > 0x7f }
    end

    def non_ascii_unicode_escape_pattern?
      analysis_source.scan(/\\u\{([^}]*)\}|\\u([0-9a-fA-F]{4})/).any? do |braced, fixed|
        digits = braced || fixed
        digits.to_i(16) > 0x7f
      end
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
      validate_bytecode_subexpression_calls(groups)
      groups.transform_values { |body| Onibi::IRGen::YARVIR::SemanticBytecode.compile(body) }
    end

    def validate_subexpression_calls!
      groups = {}
      collect_bytecode_subexpressions(@ast, groups)
      validate_bytecode_subexpression_calls(groups)
    end

    def validate_backreferences!
      walk_ast(@ast) do |node|
        if node.is_a?(Onibi::AST::Conditional)
          identifier, named = node.condition
          raise RegexpError, "undefined name <#{identifier}> condition: /#{@source}/" if named && !raw_named_captures.key?(identifier.to_s)
          raise RegexpError, "numbered backref/call is not allowed. (use name): /#{@source}/" if !named && raw_named_captures.any?
          raise RegexpError, "invalid conditional reference: /#{@source}/" if !named && identifier.to_i > capture_count
        end

        next unless node.is_a?(Onibi::AST::Backreference)

        identifier = node.identifier.to_s
        raise RegexpError, "undefined name <#{identifier}> reference: /#{@source}/" if node.named && !raw_named_captures.key?(identifier)
        next unless identifier.match?(/\A\d+\z/)
        raise RegexpError, "invalid backref number/name: /#{@source}/" if identifier.to_i > capture_count
        next if raw_named_captures.empty?

        raise RegexpError, "numbered backref/call is not allowed. (use name): /#{@source}/"
      end
    end

    def validate_bytecode_subexpression_calls(groups)
      walk_ast(@ast) do |node|
        next unless node.is_a?(Onibi::AST::SubexpressionCall)

        identifier = node.identifier.to_s
        raise RegexpError, "numbered subexpression call is not allowed with named captures" if
          identifier.match?(/\A\d+\z/) && named_captures.any?
        raise RegexpError, "never ending recursion: /#{@source}/" if identifier == "0"

        key = groups.key?(node.identifier) ? node.identifier : identifier.to_i
        raise RegexpError, "undefined subexpression call <#{node.identifier}>" unless groups.key?(key)
      end
    end

    def collect_bytecode_subexpressions(node, groups)
      case node
      when Onibi::AST::Sequence
        node.parts.each { |part| collect_bytecode_subexpressions(part, groups) }
      when Onibi::AST::Alternation
        node.branches.each { |branch| collect_bytecode_subexpressions(branch, groups) }
      when Onibi::AST::Group
        # A subexpression call re-enters the capturing group. Keep the Group
        # wrapper in bytecode, so the VM updates its capture span at call time.
        groups[node.number] = node if node.capture
        groups[node.number.to_s] = node if node.capture
        groups[node.name] = node if node.capture && node.name
        collect_bytecode_subexpressions(node.body, groups)
      when Onibi::AST::Quantifier
        collect_bytecode_subexpressions(node.expression, groups)
      when Onibi::AST::OptionGroup, Onibi::AST::AtomicGroup, Onibi::AST::Assertion
        collect_bytecode_subexpressions(node.body, groups)
      end
    end

    def analysis_source
      @analysis_source ||= if @source.encoding == Encoding::ASCII_8BIT || @source.encoding.ascii_compatible?
                             @source
                           else
                             @source.encode(Encoding::UTF_8)
                           end
    end

    def inline_global_modifier?
      return false unless analysis_source.start_with?("(?")

      close = analysis_source.index(")")
      colon = analysis_source.index(":")
      return false if colon && close && colon < close

      modifier = analysis_source[2, (colon || close || analysis_source.length) - 2].to_s
      !modifier.empty? && modifier.each_char.all? { |character| %w[i m x -].include?(character) } &&
        modifier.each_char.any? { |character| %w[i m x].include?(character) }
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
      @result_names ||= named_captures
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
require_relative "onibi/interpreter"
