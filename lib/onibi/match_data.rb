# frozen_string_literal: true

module Onibi
  # Immutable observable match result for the Core MVP.
  class MatchData
    Context = Struct.new(:string, :regexp)

    attr_reader :string, :regexp

    def initialize(values, captures, offsets, names = {}, context = nil)
      @values = ([values] + captures).freeze
      @captures = captures.freeze
      @offsets = offsets.freeze
      @names = names.freeze
      @string = context&.string
      @regexp = context&.regexp
    end

    def [](index)
      value_at(index)
    end

    def captures
      @captures.dup
    end

    def offset(index)
      @offsets.fetch(index)&.dup
    end

    def begin(index)
      @offsets.fetch(index)&.first
    end

    def end(index)
      @offsets.fetch(index)&.last
    end

    def to_a
      @values.dup
    end

    def length
      @values.length
    end

    def size
      length
    end

    def values_at(*indices)
      indices.flat_map do |index|
        index.is_a?(Range) ? index.map { |value| value_at(value) } : [value_at(index)]
      end
    end

    def pre_match
      start_position = self.begin(0)
      @string[0, start_position]
    end

    def post_match
      finish = self.end(0)
      @string[finish..] || ""
    end

    def bytebegin(index)
      offset = @offsets[index]
      offset && byte_position(offset.first)
    end

    def byteend(index)
      offset = @offsets[index]
      offset && byte_position(offset.last)
    end

    def byteoffset(index)
      return unless @offsets[index]

      [bytebegin(index), byteend(index)]
    end

    def match_length(index)
      offset = @offsets[index]
      offset && offset.last - offset.first
    end

    def named_captures
      @names.transform_values { |index| self[index] }
    end

    def names
      @names.keys
    end

    private

    def value_at(index)
      index = @names[index.to_s] if index.is_a?(String) || index.is_a?(Symbol)
      @values[index]
    end

    def byte_position(character_position)
      @string[0, character_position].bytesize
    end
  end
end
