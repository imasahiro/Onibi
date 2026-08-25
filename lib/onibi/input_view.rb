# frozen_string_literal: true

module Onibi
  # Provides a stable character cursor and byte-boundary mapping for one input.
  class InputView
    attr_reader :string, :characters

    def initialize(string, byte_mode: false)
      raise TypeError, "input must be a String" unless string.is_a?(String)

      @string = string
      @byte_mode = byte_mode
      @characters = decode_characters.freeze
      @boundaries = nil
    end

    def character_length
      boundaries.length - 1
    end

    def byte_offset(character_index)
      boundaries.fetch(normalize_character_index(character_index))
    end

    def byte_boundaries
      boundaries
    end

    def character_index(byte_offset)
      index = boundaries.bsearch_index { |boundary| boundary >= byte_offset }
      raise IndexError, "byte offset is not a character boundary" unless index && boundaries[index] == byte_offset

      index
    end

    def slice(start_character, length = nil)
      start_byte = byte_offset(start_character)
      end_byte = length.nil? ? string_bytesize : byte_offset(start_character + length)
      String.instance_method(:byteslice).bind_call(@string, start_byte, end_byte - start_byte)
    end

    private

    def decode_characters
      if @byte_mode
        return String.instance_method(:bytes).bind_call(@string).map do |byte|
          byte.chr(Encoding::ASCII_8BIT)
        end
      end

      characters = []
      String.instance_method(:each_char).bind_call(@string) { |character| characters << character }
      characters
    end

    def boundaries
      @boundaries ||= [0].tap do |result|
        cursor = 0
        @characters.each do |character|
          cursor += character.bytesize
          result << cursor
        end
      end.freeze
    end

    def string_bytesize
      String.instance_method(:bytesize).bind_call(@string)
    end

    def normalize_character_index(index)
      index += character_length if index.negative?
      index
    end
  end
end
