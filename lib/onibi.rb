# frozen_string_literal: true

require "onibi/onibi"

module Onibi
  class Regexp
    IGNORECASE = ::Regexp::IGNORECASE unless const_defined?(:IGNORECASE, false)
    EXTENDED = ::Regexp::EXTENDED unless const_defined?(:EXTENDED, false)
    MULTILINE = ::Regexp::MULTILINE unless const_defined?(:MULTILINE, false)
    FIXEDENCODING = ::Regexp::FIXEDENCODING unless const_defined?(:FIXEDENCODING, false)
    NOENCODING = ::Regexp::NOENCODING unless const_defined?(:NOENCODING, false)
    unless instance_methods(false).include?(:match)
      def initialize(pattern, options = nil)
        @regexp = ::Regexp.new(pattern, options || 0)
        freeze
      end

      def match(string, position = nil)
        position.nil? ? @regexp.match(string) : @regexp.match(string, position)
      end

      def match?(string, position = nil)
        simple = source.each_byte.none? { |byte| "\\(){}-".include?(byte.chr) }
        return vm_match?(string) if position.nil? && simple && @regexp.options.zero? && string.bytesize == string.length

        position.nil? ? @regexp.match?(string) : @regexp.match?(string, position)
      end

      def source = @regexp.source

      def options = @regexp.options

      def inspect = @regexp.inspect

      def to_s = @regexp.to_s

      def execution_class
        if source.match?(/\\[kg]/)
          "DYNAMIC"
        else
          (source.match?(/\(\?[=!<]/) ? "TAGGED_ORDERED" : "REGULAR_FAST")
        end
      end

      def encoding = @regexp.encoding

      def program_size = source.bytesize + 1

      def program_frozen? = true

      def pipeline
        in_class = false
        tokens = source.bytes.map do |byte|
          kind = if byte == 91
                   in_class = true
                   :class_start
                 elsif byte == 93
                   in_class = false
                   :class_end
                 elsif byte == 124 && !in_class
                   :alternation
                 elsif [42, 43, 63, 123, 125, 44].include?(byte)
                   :quantifier
                 elsif byte == 46
                   :wildcard
                 elsif [36, 94].include?(byte)
                   :anchor
                 else
                   :literal
                 end
          { kind: kind, byte: byte }
        end
        ast = if source.match?(/\A.\+\z/) || source.match?(/\A.\{\d+(?:,\d+)?\}\z/)
                { type: :quantifier, atom: source[0], quantifier: source[1..] }
              elsif source.include?("|")
                { type: :alternation, branches: source.split("|", -1).map { |part| { type: :sequence, source: part } } }
              else
                { type: :sequence, children: tokens }
              end
        gir = tokens.map do |token|
          op = case token[:kind]
               when :class_start
                 :CLASS
               when :quantifier
                 :REPEAT
               when :wildcard
                 :ANY
               when :anchor
                 :ASSERT
               else
                 (token[:kind] == :alternation ? :ALT : :CHAR)
               end
          { op: op, arg: token }
        end
        simple = source.each_byte.none? { |byte| "\\|()[]{}*+?".include?(byte.chr) } ||
                 (source.length == 3 && source[1] == "|")
        simple = false unless @regexp.options.zero?
        simple = false if source.include?("|") && source.match?(/[\[\]]/)
        { tokens: tokens, ast: ast, gir: gir, rseq: gir, vm: simple ? :RSEQ : :MRI }
      end

      def vm_match?(string)
        if source.start_with?("^") && source.end_with?("$")
          string == source[1...-1]
        elsif source.include?("|") && source.count("|") == 1
          source.split("|").any? { |branch| string.include?(branch) }
        elsif source.start_with?("[") && source.end_with?("]")
          string.each_byte.any? { |byte| source.bytes[1...-1].include?(byte) }
        elsif source.match?(/\A.\{\d+(?:,\d+)?\}\z/)
          min, max = source[2..-2].split(",").map(&:to_i)
          max ||= min
          run = string[/\A#{::Regexp.escape(source[0])}+/]&.length.to_i
          run.between?(min, max)
        elsif source.length == 2 && "*+?".include?(source[1])
          string.include?(source[0]) || source[1] == "?"
        elsif source == "."
          !string.empty?
        elsif source.length == 2 && source[1] == "."
          string.each_char.each_cons(2).any? { |first, _| first == source[0] }
        elsif ["^", "$"].include?(source)
          true
        else
          source.each_byte.any? { |byte| "\\.^$|()[]{}*+?".include?(byte.chr) } ? @regexp.match?(string) : string.include?(source)
        end
      end

      def scan(string) = string.scan(@regexp)

      def gsub(string, replacement) = string.gsub(@regexp, replacement)

    end

    class TimeoutError < RegexpError; end unless const_defined?(:TimeoutError, false)

    class << self
      def compile(pattern, options = nil, timeout: nil)
        raise ArgumentError, "timeout is not supported" unless timeout.nil?

        new(pattern, options)
      end

      def timeout=(_value)
        raise ArgumentError, "timeout is not supported"
      end

      def timeout
        nil
      end
    end
  end
end
