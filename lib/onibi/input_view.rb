# frozen_string_literal: true

module Onibi
  # Provides a stable character cursor and byte-boundary mapping for one input.
  class InputView
    attr_reader :string

    def initialize(string)
      raise TypeError, "input must be a String" unless string.is_a?(String)

      @string = string
      @boundaries = nil
    end

    def character_length
      boundaries.length - 1
    end

    def byte_offset(character_index)
      boundaries.fetch(normalize_character_index(character_index))
    end

    def character_index(byte_offset)
      index = boundaries.bsearch_index { |boundary| boundary >= byte_offset }
      raise IndexError, "byte offset is not a character boundary" unless index && boundaries[index] == byte_offset

      index
    end

    def slice(start_character, length = nil)
      start_byte = byte_offset(start_character)
      end_byte = length.nil? ? @string.bytesize : byte_offset(start_character + length)
      @string.byteslice(start_byte, end_byte - start_byte)
    end

    private

    def boundaries
      @boundaries ||= [0].tap do |result|
        cursor = 0
        @string.each_char do |character|
          cursor += character.bytesize
          result << cursor
        end
      end.freeze
    end

    def normalize_character_index(index)
      index += character_length if index.negative?
      index
    end
  end
end
