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
