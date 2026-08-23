# frozen_string_literal: true

module Onibi
  module Parser
    Result = Struct.new(:source, :options, :ast, keyword_init: true) do
      def initialize(source:, options:, ast:)
        super(source: source, options: options.freeze, ast: ast)
        freeze
      end
    end

    module_function

    def parse(source, options: [])
      raise TypeError, "pattern must be a String" unless source.is_a?(String)

      normalized_options = normalize_options(options)
      lex_source, normalized_options = normalize_inline_options(source, normalized_options)
      tokens = Onibi::Lexer.new(lex_source, normalized_options).tokens
      ast = Onibi::ParserCore.new(tokens).parse
      Result.new(source: source, options: normalized_options, ast: ast)
    end

    def normalize_options(options)
      case options
      when nil, false then []
      when true then ["ignorecase"]
      when Integer then integer_options(options)
      when String, Symbol then flag_options(options.to_s)
      when Array
        raise ArgumentError, "invalid options" unless options.all? { |option| valid_option?(option) }

        options.dup
      else
        raise ArgumentError, "invalid options"
      end
    end

    def valid_option?(option)
      %w[ignorecase multiline extended fixedencoding noencoding].include?(option)
    end

    def flag_options(flags)
      names = { "i" => "ignorecase", "m" => "multiline", "x" => "extended" }
      raise ArgumentError, "invalid options" unless flags.chars.all? { |flag| names.key?(flag) }

      flags.chars.map { |flag| names.fetch(flag) }.uniq
    end

    def integer_options(value)
      bits = { 1 => "ignorecase", 2 => "extended", 4 => "multiline", 16 => "fixedencoding", 32 => "noencoding" }
      supported = bits.keys.sum
      raise ArgumentError, "invalid options" if value.negative? || (value & ~supported).positive?
      raise ArgumentError, "invalid options" if (value & 48) == 48

      bits.filter_map { |bit, name| name if (value & bit).positive? }
    end

    def normalize_inline_options(source, options)
      pattern = source
      normalized = options.dup
      loop do
        break unless pattern.start_with?("(?")

        closing = pattern.index(")")
        break unless closing

        header = pattern[2...closing]
        parsed = parse_inline_header(header)
        break unless parsed

        enabled, disabled = parsed
        names = { "i" => "ignorecase", "m" => "multiline", "x" => "extended" }
        enabled.each { |flag| normalized |= [names.fetch(flag)] }
        disabled.each { |flag| normalized.delete(names.fetch(flag)) }
        pattern = pattern[(closing + 1)..]
      end
      [pattern, normalized]
    end

    def parse_inline_header(header)
      return if header.empty? || header.start_with?("#") || header.include?(":")

      parts = header.split("-", -1)
      return unless parts.length <= 2

      enabled = parts.first.chars
      disabled = parts.length == 2 ? parts.last.chars : []
      flags = enabled + disabled
      return unless !flags.empty? && flags.all? { |flag| %w[i m x].include?(flag) }
      return if flags.uniq.length != flags.length
      return if (enabled & disabled).any?

      [enabled, disabled]
    end
    private_class_method :normalize_options, :valid_option?, :flag_options, :integer_options,
                         :normalize_inline_options, :parse_inline_header
    class EntryPoint
      def initialize(source, options = [])
        @source = source
        @options = options
      end

      def parse
        Parser.parse(@source, options: @options).ast
      end
    end

    def self.new(source, options = [])
      EntryPoint.new(source, options)
    end
  end
end
