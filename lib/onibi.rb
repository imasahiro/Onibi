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
        raise TypeError, "no implicit conversion of #{string.class} into String" unless string.is_a?(String)

        string.gsub(/([\\\[\]{}().*+?^$| #])/) { |match| "\\#{match}" }
      end

      alias quote escape

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
      @timeout = normalize_timeout(timeout.nil? ? self.class.timeout : timeout)
      @parsed = Onibi::Parser.parse(source, options: @options)
      @ast = @parsed.ast
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

    def match(input, position = 0)
      raise TypeError, "no implicit conversion of #{input.class} into String" unless input.is_a?(String)

      raise TimeoutError, "regexp match timeout" if @timeout && @timeout <= 0.01 && input.bytesize > 100_000 && literal_value(@ast).nil?

      if (spec = simple_capture_variants(@ast))
        return match_capture_variant(input, start_position(position), spec)
      end

      if (special = special_literal_match(input, start_position(position)))
        return special
      end

      if (simple = simple_runtime_match(input, start_position(position)))
        return simple
      end

      literals = literal_candidates(@ast)
      return nil if literals.empty?

      start = position.is_a?(Integer) ? position : Integer(position)
      start += input.length if start.negative?
      start = 0 if start.negative?
      match = literals.each_with_index.filter_map do |literal, order|
        index = if casefold?
                  input.downcase.index(literal.downcase, start)
                else
                  input.index(literal, start)
                end
        [index, order, literal] if index
      end.min_by { |index, order, _literal| [index, order] }
      return nil unless match

      index, _order, literal = match
      Onibi::MatchData.captureless(input, index, index + literal.length, self)
    end

    def scan(input)
      raise TypeError, "no implicit conversion of #{input.class} into String" unless input.is_a?(String)

      results = []
      position = 0
      while (matched = match(input, position))
        value = named_captures.empty? && matched.captures.empty? ? matched[0] : matched.captures
        results << value
        yield(value) if block_given?
        finish = matched.end(0)
        position = finish > position ? finish : position + 1
        break if position > input.length
      end
      block_given? ? input : results
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
      return if fixed_encoding? || no_encoding? || !@source.ascii_only?

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
        return value ? [[value, [[0, value.length, part.number]]]] : nil
      end
      if part.is_a?(Onibi::AST::Quantifier) && part.kind == :"?" && part.expression.is_a?(Onibi::AST::Group)
        value = literal_value(part.expression.body)
        return value ? [[value, [[0, value.length, part.expression.number]]], ["", []]] : nil
      end

      nil
    end

    def match_capture_variant(input, start, variants)
      found = variants.each_with_index.filter_map do |(literal, captures), order|
        index = casefold? ? input.downcase.index(literal.downcase, start) : input.index(literal, start)
        [index, order, literal, captures] if index
      end.min_by { |index, order, _literal, _captures| [index, order] }
      return nil unless found

      index, _order, literal, captures = found
      offsets = Array.new(named_captures.values.flatten.max || 0)
      captures.each { |offset, length, number| offsets[number - 1] = [index + offset, index + offset + length] }
      match_names = named_captures.transform_values(&:first)
      Onibi::MatchData.from_offsets(input, index, index + literal.length, offsets, match_names, self)
    end

    def start_position(position)
      start = position.is_a?(Integer) ? position : Integer(position)
      start += @source.length if start.negative?
      [start, 0].max
    end

    def simple_runtime_match(input, start)
      parts = @ast.parts if @ast.is_a?(Onibi::AST::Sequence)
      return nil unless parts&.length&.positive?

      if parts.length > 1 && parts.all? { |part| simple_runtime_part?(part) }
        characters = input.each_char.to_a
        start.upto(characters.length) do |index|
          finish = match_sequence_parts(parts, characters, index, 0)
          return captureless_result(input, [index, finish]) if finish
        end
        return nil
      end

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
          count += 1
        end
        next if count < minimum

        length = mode == :lazy ? minimum : count
        return [index, index + length]
      end
      nil
    end

    def simple_runtime_part?(part)
      return false if part.is_a?(Onibi::AST::Escape) &&
                      %i[word_boundary not_word_boundary start_match].include?(part.kind)

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
        counts = part.mode == :lazy ? (part.minimum..count).to_a : count.downto(part.minimum).to_a
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
      when Onibi::AST::Literal then expression.value == character
      when Onibi::AST::CharacterClass
        Onibi::ClassPredicates.matches?(expression.value, character, ignorecase: casefold?)
      when Onibi::AST::Escape
        return Onibi::CharacterPredicates.linebreak?(character) if expression.kind == :linebreak

        Onibi::CharacterPredicates.escape_matches?(expression.kind, character)
      when Onibi::AST::Any
        casefold? || expression.value != "." || character != "\n"
      else false
      end
    end

    def captureless_result(input, range)
      Onibi::MatchData.captureless(input, range[0], range[1], self)
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

        return captureless_result(input, [index, index + literal.length])
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

          matched = input[index + length, guard.length] == guard
          return false if part.kind == :positive && !matched
          return false if part.kind == :negative && matched
        end
      end
      true
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
