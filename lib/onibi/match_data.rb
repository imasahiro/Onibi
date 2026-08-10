# frozen_string_literal: true

module Onibi
  # Immutable observable match result for the Core MVP.
  class MatchData
    def initialize(values, captures, offsets, names = {})
      @values = ([values] + captures).freeze
      @captures = captures.freeze
      @offsets = offsets.freeze
      @names = names.freeze
    end

    def [](index)
      @values[index]
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
        index.is_a?(Range) ? index.map { |value| @values[value] } : [@values[index]]
      end
    end

    def named_captures
      @names.transform_values { |index| self[index] }
    end
  end
end
