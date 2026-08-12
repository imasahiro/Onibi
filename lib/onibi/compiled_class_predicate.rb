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
        @ascii = Array.new(128) do |codepoint|
          ClassPredicates.match_source(@source, codepoint.chr(Encoding::ASCII), @ignorecase)
        end.freeze
        freeze
      end

      def matches?(character)
        character = character.chr(@source.encoding) if character.is_a?(Integer)
        return false unless character
        return @ascii[character.ord] if character.length == 1 && character.ord < 128

        ClassPredicates.match_source(@source, character, @ignorecase)
      rescue RangeError
        false
      end
    end
  end
end
