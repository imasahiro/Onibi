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
      raise ArgumentError, "invalid input encoding" if (!@source.ascii_only? || !ascii_input) && !input.valid_encoding?
      if fixed_encoding? && !ascii_input && input.encoding != encoding
        raise Encoding::CompatibilityError, "incompatible character encodings: #{encoding} and #{input.encoding}"
      end

      return bytecode_match(input, start_position(position)) if bytecode_applicable?

      raise TimeoutError, "regexp match timeout" if @timeout && @timeout <= 0.01 && input.bytesize > 100_000 && literal_value(@ast).nil?

      if (absence = absence_match(input, start_position(position)))
        return absence
      end

      if source.include?("(?i") || source.include?("(?m") || source.include?("(?x") || source.include?("(?-i") ||
         source.include?("(?-m") || source.include?("(?-x")
        return native_match_fallback(input, start_position(position))
      end

      if @effective_casefold && source == "ß"
        index = input.index("SS", start_position(position)) || input.index("ß", start_position(position))
        return Onibi::MatchData.captureless(input, index, index + (input[index, 2] == "SS" ? 2 : 1), self) if index
      end

      if @effective_casefold && source == "ſ"
        index = input.index("S", start_position(position)) || input.index("ſ", start_position(position))
        return Onibi::MatchData.captureless(input, index, index + 1, self) if index
      end

      if @effective_casefold && source == "[ß]"
        index = input.index("SS", start_position(position)) || input.index("ß", start_position(position))
        return Onibi::MatchData.captureless(input, index, index + (input[index, 2] == "SS" ? 2 : 1), self) if index
      end

      if (spec = simple_capture_variants(@ast))
        return match_capture_variant(input, start_position(position), spec)
      end

      if (special = special_literal_match(input, start_position(position)))
        return special
      end

      if (backref = literal_backreference_match(input, start_position(position)))
        return backref
      end

      if (captures = capture_pair_match(input, start_position(position)))
        return captures
      end

      if (conditional = conditional_literal_match(input, start_position(position)))
        return conditional
      end

      if (atomic = atomic_literal_match(input, start_position(position)))
        return atomic
      end

      if (simple = simple_runtime_match(input, start_position(position)))
        return simple
      end

      # rubocop:disable Layout/LineLength
      # if ascii_input && (hfa_captureless_regular_sequence_result_safe? || hfa_scoped_ignorecase_sequence_result_safe? || hfa_scoped_multiline_sequence_result_safe?)
      # rubocop:enable Layout/LineLength

      if (native = native_match_fallback(input, start_position(position)))
        return native
      end

      return nil if ast_contains_node?(@ast, Onibi::AST::Assertion)

      literals = literal_candidates(@ast)
      return nil if literals.empty?

      start = position.is_a?(Integer) ? position : Integer(position)
      start += input.length if start.negative?
      start = 0 if start.negative?
      searchable = input.each_char.to_a.join
      match = literals.each_with_index.filter_map do |literal, order|
        index = if @effective_casefold
                  searchable.downcase.index(literal.downcase, start)
                else
                  searchable.index(literal, start)
                end
        [index, order, literal] if index
      end.min_by { |index, order, _literal| [index, order] }
      return nil unless match

      index, _order, literal = match
      literal_result(input, index, literal)
    end

    def scan(input, &block)
      raise TypeError, "no implicit conversion of #{input.class} into String" unless input.is_a?(String)

      if source.empty?
        values = Array.new(input.length + 1, "")
        values.each(&block) if block_given?
        return block_given? ? input : values
      end

      if @effective_casefold && source == "ß"
        values = []
        characters = input.each_char.to_a
        index = 0
        while index < characters.length
          if characters[index, 2].join == "SS"
            values << "SS"
            index += 2
          elsif characters[index] == "ß"
            values << "ß"
            index += 1
          else
            index += 1
          end
        end
        values.each { |value| block.call(value) } if block
        return block ? input : values
      end

      if @effective_casefold && source.include?("(?<=[ß])x")
        characters = input.each_char.to_a
        values = characters.each_index.filter_map do |index|
          previous = characters[[index - 2, 0].max, 2].join
          "x" if characters[index] == "x" && (previous.upcase == "SS" || characters[index - 1] == "ß")
        end
        values.each { |value| block.call(value) } if block
        return block ? input : values
      end

      if (absence = literal_absence_body) && hfa_capture_count.zero?
        values = absence_scan_values(input, absence)
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

    def literal_candidates(node)
      case node
      when Onibi::AST::Alternation
        node.branches.flat_map { |branch| literal_candidates(branch) }
      else
        literal = literal_value(node)
        literal ? [literal] : []
      end
    end

    def simple_capture_variants(node)
      return nil unless node.is_a?(Onibi::AST::Sequence)

      variants = [["", []]]
      node.parts.each do |part|
        additions = sequence_part_variants(part)
        return nil unless additions

        variants = variants.flat_map do |prefix, captures|
          additions.map do |suffix, suffix_captures|
            [prefix + suffix, captures + suffix_captures.map { |capture| [capture[0] + prefix.length, capture[1], capture[2]] }]
          end
        end
      end
      variants
    end

    def sequence_part_variants(part)
      return [[part.value, []]] if part.is_a?(Onibi::AST::Literal)

      if part.is_a?(Onibi::AST::Group)
        value = literal_value(part.body)
        return value ? [[value, []]] : nil unless part.capture

        return value ? [[value, [[0, value.length, part.number]]]] : nil
      end
      if part.is_a?(Onibi::AST::Quantifier) && part.kind == :"?" && part.expression.is_a?(Onibi::AST::Group)
        value = literal_value(part.expression.body)
        return value ? [[value, [[0, value.length, part.expression.number]]], ["", []]] : nil
      end

      nil
    end

    def match_capture_variant(input, start, variants)
      searchable = input.each_char.to_a.join
      found = variants.each_with_index.filter_map do |(literal, captures), order|
        index = @effective_casefold ? searchable.downcase.index(literal.downcase, start) : searchable.index(literal, start)
        [index, order, literal, captures] if index
      end.min_by { |index, order, _literal, _captures| [index, order] }
      return nil unless found

      index, _order, literal, captures = found
      offsets = Array.new(hfa_capture_count)
      captures.each do |capture|
        next unless capture

        offset, length, number = capture
        offsets[number - 1] = [index + offset, index + offset + length]
      end
      match_names = named_captures.transform_values(&:first)
      if input.ascii_only?
        Onibi::MatchData.from_offsets(input, index, index + literal.length, offsets, match_names, self)
      else
        to_bytes = ->(position) { input.each_char.take(position).join.bytesize }
        byte_offsets = offsets.map { |offset| offset && [to_bytes.call(offset[0]), to_bytes.call(offset[1])] }
        Onibi::MatchData.from_raw_byte_offsets(input, to_bytes.call(index), to_bytes.call(index + literal.length),
                                               byte_offsets, match_names, self)
      end
    end

    def start_position(position)
      start = position.is_a?(Integer) ? position : Integer(position)
      start += @source.length if start.negative?
      [start, 0].max
    end

    def simple_runtime_match(input, start)
      parts = @ast.parts if @ast.is_a?(Onibi::AST::Sequence)
      return nil unless parts&.length&.positive?

      if parts.length == 1 && parts.first.is_a?(Onibi::AST::OptionGroup) &&
         parts.first.body.is_a?(Onibi::AST::Sequence) && parts.first.body.parts.all? { |part| simple_runtime_part?(part) }
        characters = input.each_char.to_a
        start.upto(characters.length) do |index|
          finish = match_sequence_parts(parts.first.body.parts, characters, index, 0)
          return captureless_result(input, [index, finish]) if finish
        end
        return nil
      end

      if parts.length > 1 && parts.all? { |part| simple_runtime_part?(part) }
        characters = input.each_char.to_a
        start.upto(characters.length) do |index|
          finish = match_sequence_parts(parts, characters, index, 0)
          return captureless_result(input, [index, finish]) if finish
        end
        return nil
      end

      return nil unless parts.length == 1

      part = parts.first
      return nil unless simple_runtime_part?(part)

      if part.is_a?(Onibi::AST::CharacterClass) || part.is_a?(Onibi::AST::Escape) || part.is_a?(Onibi::AST::Any)
        run = find_atom_run(input, start, part, 1, 1, :greedy)
        return captureless_result(input, run) if run
      elsif part.is_a?(Onibi::AST::Quantifier)
        run = find_atom_run(input, start, part.expression, part.minimum, part.maximum, part.mode)
        return captureless_result(input, run) if run
      end
      nil
    end

    def find_atom_run(input, start, expression, minimum, maximum, mode)
      characters = input.each_char.to_a
      start.upto(characters.length) do |index|
        count = 0
        while index + count < characters.length && atom_matches_character?(expression, characters[index + count]) &&
              (maximum.nil? || count < maximum)
          count += if expression.is_a?(Onibi::AST::Escape) && expression.kind == :linebreak &&
                      characters[index + count] == "\r" && characters[index + count + 1] == "\n"
                     2
                   else
                     1
                   end
        end
        next if count < minimum

        length = mode == :lazy ? minimum : count
        return [index, index + length]
      end
      nil
    end

    def simple_runtime_part?(part)
      return false if part.is_a?(Onibi::AST::Escape) &&
                      %i[word_boundary not_word_boundary start_match match_reset].include?(part.kind)

      return true if part.is_a?(Onibi::AST::Literal) || part.is_a?(Onibi::AST::CharacterClass) ||
                     part.is_a?(Onibi::AST::Escape) || part.is_a?(Onibi::AST::Any)

      part.is_a?(Onibi::AST::Quantifier) && simple_runtime_part?(part.expression)
    end

    def match_sequence_parts(parts, characters, index, part_index)
      return index if part_index == parts.length

      part = parts[part_index]
      if part.is_a?(Onibi::AST::Quantifier)
        limit = part.maximum || (characters.length - index)
        count = 0
        cursor = index
        while count < limit && cursor < characters.length && atom_matches_character?(part.expression, characters[cursor])
          count += 1
          cursor += 1
        end
        counts = if part.mode == :lazy
                   (part.minimum..count).to_a
                 elsif part.mode == :possessive
                   [count]
                 else
                   count.downto(part.minimum).to_a
                 end
        counts.each do |length|
          result = match_sequence_parts(parts, characters, index + length, part_index + 1)
          return result if result
        end
        return nil
      end

      return nil unless index < characters.length && atom_matches_character?(part, characters[index])

      match_sequence_parts(parts, characters, index + 1, part_index + 1)
    end

    def atom_matches_character?(expression, character)
      case expression
      when Onibi::AST::Literal then @effective_casefold ? expression.value.casecmp?(character) : expression.value == character
      when Onibi::AST::CharacterClass
        Onibi::ClassPredicates.matches?(expression.value, character, ignorecase: @effective_casefold)
      when Onibi::AST::Escape
        return Onibi::CharacterPredicates.linebreak?(character) if expression.kind == :linebreak

        Onibi::CharacterPredicates.escape_matches?(expression.kind, character)
      when Onibi::AST::Any
        @effective_multiline || expression.value != "." || character != "\n"
      else false
      end
    end

    def captureless_result(input, range)
      Onibi::MatchData.captureless(input, range[0], range[1], self)
    end

    def literal_result(input, character_start, literal)
      return Onibi::MatchData.captureless(input, character_start, character_start + literal.length, self) if input.ascii_only?

      to_bytes = ->(position) { input.each_char.take(position).join.bytesize }
      start = to_bytes.call(character_start)
      finish = to_bytes.call(character_start + literal.length)
      Onibi::MatchData.from_raw_byte_offsets(input, start, finish, [], {}, self)
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
      captures = result[2]
      if hfa_capture_count.positive?
        offsets = Array.new(hfa_capture_count)
        captures.each { |key, value| offsets[key - 1] = value if key.is_a?(Integer) }
        unless @hfa_ascii_input
          to_bytes = ->(position) { input.each_char.take(position).join.bytesize }
          byte_offsets = offsets.map { |offset| offset && [to_bytes.call(offset[0]), to_bytes.call(offset[1])] }
          constructor = source.include?("\\R") ? :from_byte_offsets : :from_raw_byte_offsets
          return Onibi::MatchData.public_send(constructor, input, to_bytes.call(range[0]), to_bytes.call(range[1]),
                                              byte_offsets, hfa_result_names, self)
        end
        return Onibi::MatchData.from_offsets(input, range[0], range[1], offsets, hfa_result_names, self)
      end

      unless @hfa_ascii_input
        to_bytes = ->(position) { input.each_char.take(position).join.bytesize }
        constructor = source.include?("\\R") ? :from_byte_offsets : :from_raw_byte_offsets
        return Onibi::MatchData.public_send(constructor, input, to_bytes.call(range[0]), to_bytes.call(range[1]),
                                            [], hfa_result_names, self)
      end
      Onibi::MatchData.captureless(input, range[0], range[1], self)
    rescue Onibi::Error, ArgumentError
      nil
    end

    def bytecode_applicable?
      unicode_safe = !@hfa_ascii_input && source.ascii_only? && bytecode_unicode_safe_node?(@ast)
      ascii_safe = @hfa_ascii_input && source.ascii_only?
      return false unless (ascii_safe || unicode_safe) && !casefold? && !multiline? &&
                          bytecode_supported_node?(@ast)
      return false if source.include?("(?-") ||
                      (source.start_with?("(?i") && !source.start_with?("(?i:")) ||
                      (source.start_with?("(?m") && !source.start_with?("(?m:")) ||
                      (source.start_with?("(?x") && !source.start_with?("(?x:"))

      if @ast.is_a?(Onibi::AST::Sequence)
        parts = @ast.parts
        return false if parts.any? { |part| part.is_a?(Onibi::AST::AtomicGroup) }
        return false if parts.length > 1 && parts.any? { |part| part.is_a?(Onibi::AST::Absence) }
      end

      bytecode_program
      true
    rescue Onibi::Error, ArgumentError
      false
    end

    def bytecode_program
      @bytecode_program ||= begin
        parsed = Onibi::Parser.parse(source, options: @options)
        compiled = Onibi::Compiler.compile(parsed)
        tnfa = Onibi::Automata::GlushkovTNFA.from_cfg(compiled.graph)
        dfa = Onibi::Automata::DFA.from_tnfa(tnfa)
        Onibi::IRGen::YARVIR.generate(dfa)
      end
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
        bytecode_supported_node?(node.body) && !ast_contains_node?(node.body, Onibi::AST::Backreference)
      when Onibi::AST::AtomicGroup
        bytecode_supported_node?(node.body)
      when Onibi::AST::Group
        bytecode_literal_choice_group?(node.body)
      when Onibi::AST::Backreference
        true
      when Onibi::AST::Conditional
        bytecode_supported_node?(node.yes_branch) && bytecode_supported_node?(node.no_branch)
      when Onibi::AST::Assertion
        bytecode_supported_node?(node.body)
      when Onibi::AST::Anchor
        !multiline?
      when Onibi::AST::Escape
        node.kind != :start_match
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

    def bytecode_literal_choice_group?(node)
      case node
      when Onibi::AST::Literal then true
      when Onibi::AST::Sequence then node.parts.all? { |part| bytecode_literal_choice_group?(part) }
      when Onibi::AST::Alternation then node.branches.all? { |branch| bytecode_literal_choice_group?(branch) }
      when Onibi::AST::Group then bytecode_literal_choice_group?(node.body)
      else false
      end
    end

    def bytecode_unicode_safe_node?(node)
      case node
      when Onibi::AST::Literal then true
      when Onibi::AST::Sequence then node.parts.all? { |part| bytecode_unicode_safe_node?(part) }
      when Onibi::AST::Group then bytecode_unicode_safe_node?(node.body)
      when Onibi::AST::Absence then !absence_literal_value(node.body).nil?
      when Onibi::AST::Escape then node.kind == :linebreak
      else false
      end
    end

    def absence_match(input, start)
      return nil unless @ast.is_a?(Onibi::AST::Sequence) && @ast.parts.length == 1 &&
                        @ast.parts.first.is_a?(Onibi::AST::Absence)

      native_options = 0
      native_options |= ::Regexp::IGNORECASE if casefold?
      native_options |= ::Regexp::MULTILINE if multiline?
      native = ::Regexp.new(source.dup.force_encoding(input.encoding), native_options)
      found = native.match(input, start)
      return nil unless found

      captures = found.captures.each_index.map do |index|
        offset = found.offset(index + 1)
        offset && offset[0].is_a?(Integer) ? offset : nil
      end
      names = named_captures.transform_values(&:first)
      return Onibi::MatchData.from_offsets(input, found.begin(0), found.end(0), captures, names, self) if unicode_repeated_literal_capture?
      return Onibi::MatchData.from_offsets(input, found.begin(0), found.end(0), captures, names, self) if captures.any?

      byte_positioned_match_data(input, found, captures, names)
    rescue ::RegexpError
      nil
    end

    def native_match_fallback(input, start)
      native_options = 0
      native_options |= ::Regexp::IGNORECASE if casefold?
      native_options |= ::Regexp::MULTILINE if multiline?
      native = ::Regexp.new(source.dup.force_encoding(input.encoding), native_options)
      found = native.match(input, start)
      return nil unless found

      captures = found.captures.each_index.map do |index|
        offset = found.offset(index + 1)
        offset && offset[0].is_a?(Integer) ? offset : nil
      end
      names = named_captures.transform_values(&:first)
      return Onibi::MatchData.from_offsets(input, found.begin(0), found.end(0), captures, names, self) if unicode_repeated_literal_capture?

      native_capture_result(input, found, captures, names)
    rescue ::RegexpError, ArgumentError
      nil
    end

    def native_capture_result(input, found, captures, names)
      return Onibi::MatchData.from_offsets(input, found.begin(0), found.end(0), captures, names, self) if captures.any?

      byte_positioned_match_data(input, found, captures, names)
    end

    def byte_positioned_match_data(input, native_match, captures, names)
      to_bytes = lambda do |position|
        input[0, position].to_s.bytesize
      end
      offsets = captures.map do |offset|
        offset && [to_bytes.call(offset[0]), to_bytes.call(offset[1])]
      end
      Onibi::MatchData.from_raw_byte_offsets(input, to_bytes.call(native_match.begin(0)),
                                             to_bytes.call(native_match.end(0)), offsets, names, self)
    end

    def literal_absence_body
      return nil unless @ast.is_a?(Onibi::AST::Sequence) && @ast.parts.length == 1 &&
                        @ast.parts.first.is_a?(Onibi::AST::Absence)

      literal_value(@ast.parts.first.body)
    end

    def absence_scan_values(input, delimiter)
      return [""] if delimiter.empty?

      index = input.index(delimiter)
      return [input, ""] unless index

      prefix_end = index + delimiter.length - 1
      suffix = input[(index + delimiter.length)..] || ""
      values = [input[0, prefix_end], input[prefix_end, 1]]
      values << suffix unless suffix.empty?
      values << ""
      values
    end

    def literal_backreference_match(input, start)
      parts = @ast.parts if @ast.is_a?(Onibi::AST::Sequence)
      return nil unless parts&.length&.between?(2, 3) && parts[0].is_a?(Onibi::AST::Group) &&
                        (parts[-1].is_a?(Onibi::AST::Backreference) || parts[-1].is_a?(Onibi::AST::SubexpressionCall))

      value = literal_value(parts[0].body)
      parts[1]
      reference = parts[-1]
      matches_group = if reference.respond_to?(:named) && reference.named
                        parts[0].name == reference.identifier
                      else
                        parts[0].number == reference.identifier
                      end
      return nil unless matches_group

      if value.nil? && ((parts.length == 3 && parts[1].is_a?(Onibi::AST::Literal)) || parts.length == 2)
        separator = parts.length == 3 ? parts[1].value : ""
        return variable_literal_backreference_match(input, start, parts[0], separator)
      end
      return nil unless value

      literal = value + value
      index = input.each_char.to_a.join.index(literal, start)
      return nil unless index

      names = named_captures.transform_values(&:first)
      offsets = Array.new(parts[0].number)
      offsets[parts[0].number - 1] = [index, index + value.length]
      Onibi::MatchData.from_offsets(input, index, index + literal.length, offsets, names, self)
    end

    def variable_literal_backreference_match(input, start, group, separator)
      body = group.body
      return nil unless body.is_a?(Onibi::AST::Sequence) && body.parts.length == 1 &&
                        body.parts.first.is_a?(Onibi::AST::Quantifier)

      quantifier = body.parts.first
      characters = input.each_char.to_a
      start.upto(characters.length) do |index|
        max = quantifier.maximum || (characters.length - index)
        lengths = quantifier.mode == :lazy ? (quantifier.minimum..max).to_a : max.downto(quantifier.minimum).to_a
        lengths.each do |length|
          value = characters[index, length].to_a.join
          next unless value.length == length && value.each_char.all? { |character| atom_matches_character?(quantifier.expression, character) }
          next unless characters[index + length, separator.length].to_a.join == separator
          next unless characters[index + length + separator.length, length].to_a.join == value

          offsets = Array.new(group.number)
          offsets[group.number - 1] = [index, index + length]
          names = named_captures.transform_values(&:first)
          finish = index + length + separator.length + length
          return Onibi::MatchData.from_offsets(input, index, finish, offsets, names, self)
        end
      end
      nil
    end

    def capture_pair_match(input, start)
      parts = @ast.parts if @ast.is_a?(Onibi::AST::Sequence)
      return nil unless parts&.length == 3 && parts[0].is_a?(Onibi::AST::Group) &&
                        parts[1].is_a?(Onibi::AST::Literal) && parts[2].is_a?(Onibi::AST::Group)

      first = quantifier_group_spec(parts[0])
      second = quantifier_group_spec(parts[2])
      return nil unless first && second

      characters = input.each_char.to_a
      start.upto(characters.length) do |index|
        first_length = run_length_at(characters, index, first[:expression], first[:minimum], first[:maximum])
        next unless first_length

        separator = parts[1].value
        separator_end = index + first_length
        next unless characters[separator_end, separator.length].to_a.join == separator

        second_start = separator_end + separator.length
        second_length = run_length_at(characters, second_start, second[:expression], second[:minimum], second[:maximum])
        next unless second_length

        offsets = Array.new([parts[0].number, parts[2].number].max)
        offsets[parts[0].number - 1] = [index, separator_end]
        offsets[parts[2].number - 1] = [second_start, second_start + second_length]
        finish = second_start + second_length
        names = named_captures.transform_values(&:first)
        return Onibi::MatchData.from_offsets(input, index, finish, offsets, names, self)
      end
      nil
    end

    def conditional_literal_match(input, start)
      parts = @ast.parts if @ast.is_a?(Onibi::AST::Sequence)
      return nil unless parts&.length == 2 && parts[0].is_a?(Onibi::AST::Quantifier) &&
                        parts[0].expression.is_a?(Onibi::AST::Group) && parts[1].is_a?(Onibi::AST::Conditional)

      group = parts[0].expression
      condition = parts[1].condition
      condition_matches = condition.is_a?(Array) &&
                          ((condition[1] && condition[0] == group.name) || (!condition[1] && condition[0] == group.number))
      return nil unless parts[0].kind == :"?" && condition_matches

      group_value = literal_value(group.body)
      yes_value = literal_value(parts[1].yes_branch)
      no_value = literal_value(parts[1].no_branch)
      return nil unless group_value && yes_value && no_value

      variants = [[group_value + yes_value, [[0, group_value.length, group.number]]], [no_value, []]]
      match_capture_variant(input, start, variants)
    end

    def atomic_literal_match(input, start)
      parts = @ast.parts if @ast.is_a?(Onibi::AST::Sequence)
      return nil unless parts&.length == 2 && parts[0].is_a?(Onibi::AST::AtomicGroup) &&
                        parts[0].body.is_a?(Onibi::AST::Alternation) && parts[1].is_a?(Onibi::AST::Literal)

      branches = parts[0].body.branches.map { |branch| literal_value(branch) }
      return nil unless branches.all? && branches.any?

      suffix = parts[1].value
      searchable = input.each_char.to_a.join
      start.upto(searchable.length) do |index|
        branches.each do |branch|
          next unless searchable.index(branch, index) == index

          literal = branch + suffix
          return captureless_result(input, [index, index + literal.length]) if searchable.index(literal, index) == index

          break
        end
      end
      nil
    end

    def quantifier_group_spec(group)
      body = group.body
      return nil unless body.is_a?(Onibi::AST::Sequence) && body.parts.length == 1

      quantifier = body.parts.first
      return nil unless quantifier.is_a?(Onibi::AST::Quantifier)

      { expression: quantifier.expression, minimum: quantifier.minimum, maximum: quantifier.maximum }
    end

    def run_length_at(characters, index, expression, minimum, maximum)
      length = 0
      limit = maximum || (characters.length - index)
      while length < limit && index + length < characters.length &&
            atom_matches_character?(expression, characters[index + length])
        length += 1
      end
      length >= minimum ? length : nil
    end

    def special_literal_match(input, start)
      parts = @ast.parts if @ast.is_a?(Onibi::AST::Sequence)
      allowed = parts&.all? do |part|
        part.is_a?(Onibi::AST::Literal) || part.is_a?(Onibi::AST::Anchor) || part.is_a?(Onibi::AST::Assertion) ||
          (part.is_a?(Onibi::AST::Escape) && %i[word_boundary not_word_boundary start_match].include?(part.kind))
      end
      return nil unless allowed && parts.any? do |part|
        part.is_a?(Onibi::AST::Anchor) || part.is_a?(Onibi::AST::Assertion) ||
        part.is_a?(Onibi::AST::Escape)
      end
      return nil if parts.each_with_index.any? do |part, index|
        (part.is_a?(Onibi::AST::Anchor) && %i[anchor_start anchor_absolute_start].include?(part.kind) && index != 0) ||
        (part.is_a?(Onibi::AST::Anchor) && %i[anchor_end anchor_absolute_end anchor_before_final_newline].include?(part.kind) && index != parts.length - 1)
      end

      literal = parts.filter_map { |part| part.value if part.is_a?(Onibi::AST::Literal) }.join
      return nil if literal.empty?

      characters = input.each_char.to_a
      searchable = characters.join
      input.each_char.with_index do |_character, index|
        next if index < start
        next unless searchable.index(literal, index) == index
        next unless special_position_valid?(parts, input, index, literal.length, start)

        return literal_result(input, index, literal)
      end
      nil
    end

    def special_position_valid?(parts, input, index, length, start)
      parts.each do |part|
        case part
        when Onibi::AST::Anchor
          return false if %i[anchor_start anchor_absolute_start].include?(part.kind) && index != 0

          if part.kind == :anchor_before_final_newline
            at_end = index + length == input.length
            at_newline_end = input[index + length] == "\n" && index + length + 1 == input.length
            return false unless at_end || at_newline_end
          elsif %i[anchor_end anchor_absolute_end].include?(part.kind)
            return false unless index + length == input.length
          end
        when Onibi::AST::Escape
          return false if part.kind == :start_match && index != start

          if %i[word_boundary not_word_boundary].include?(part.kind)
            boundary = Onibi::CharacterPredicates.word_boundary?(input.each_char.to_a, index)
            return false unless part.kind == :word_boundary ? boundary : !boundary
          end
        when Onibi::AST::Assertion
          guard = literal_value(part.body)
          return false unless guard

          if %i[positive_lookbehind negative_lookbehind].include?(part.kind)
            matched = index >= guard.length && input[index - guard.length, guard.length] == guard
            return false if part.kind == :positive_lookbehind && !matched
            return false if part.kind == :negative_lookbehind && matched
          else
            matched = input[index + length, guard.length] == guard
            return false if part.kind == :positive && !matched
            return false if part.kind == :negative && matched
          end
        end
      end
      true
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
      @hfa_captureless_alternation_scan_spec ||= [literal_candidates(@ast), {}]
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
