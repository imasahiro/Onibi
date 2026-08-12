# frozen_string_literal: true

module Onibi
  # Character-class compilation helpers.
  module ClassPredicates
    module_function

    def compiled(source, ignorecase: false)
      cache = (@compiled_cache ||= {})
      key = [source, ignorecase == true].freeze
      cache[key] ||= Compiled.new(source, ignorecase == true)
    end

    # Immutable ASCII lookup table with source-backed fallback for other input.
    class Compiled
      attr_reader :source

      def initialize(source, ignorecase)
        @source = source.dup.freeze
        @ignorecase = ignorecase
        @ascii = Array.new(256) do |codepoint|
          ClassPredicates.match_source(@source, codepoint.chr(Encoding::ASCII_8BIT), @ignorecase)
        end.freeze
        freeze
      end

      def ascii_table_length
        @ascii.length
      end

      def matches_byte?(byte)
        byte.is_a?(Integer) && byte.between?(0, 255) && @ascii[byte]
      end

      def matches?(character)
        character = character.chr(@source.encoding) if character.is_a?(Integer)
        return false unless character
        if character.length == 1 && character.ord < 256 &&
           (character.encoding == Encoding::ASCII_8BIT || character.ord < 128)
          return @ascii[character.ord]
        end

        ClassPredicates.match_source(@source, character, @ignorecase)
      rescue RangeError
        false
      end
    end
  end
end
