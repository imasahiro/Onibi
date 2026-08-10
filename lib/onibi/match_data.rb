# frozen_string_literal: true

module Onibi
  # Immutable observable match result for the Core MVP.
  class MatchData
    include MatchDataDestructuring
    include MatchDataOffsets

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

    def named_captures
      @names.transform_values { |index| self[index] }
    end

    def names
      @names.keys
    end

    def to_s
      self[0]
    end

    def inspect
      details = @names.map { |name, index| "#{name}:#{self[index].inspect}" }
      suffix = details.empty? ? "" : " #{details.join(" ")}"
      "#<MatchData #{self[0].inspect}#{suffix}>"
    end

    def ==(other)
      other.is_a?(MatchData) && match_identity == other.send(:match_identity)
    end

    def eql?(other)
      self == other
    end

    def hash
      match_identity.hash
    end

    private

    def match_identity
      [@values, @offsets, @string, @regexp]
    end

    def value_at(index)
      if index.is_a?(String) || index.is_a?(Symbol)
        name = index.to_s
        raise IndexError, "undefined group name reference: #{name}" unless @names.key?(name)

        index = @names[name]
      end
      return nil if index.is_a?(Integer) && index.negative? && index < -@captures.length

      @values[index]
    end
  end
end
