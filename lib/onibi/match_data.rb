# frozen_string_literal: true

module Onibi
  # Immutable observable match result for the Core MVP.
  class MatchData
    include MatchDataDestructuring
    include MatchDataOffsets

    Context = Struct.new(:string, :regexp)

    attr_reader :string, :regexp

    EMPTY_CAPTURES = [].freeze
    EMPTY_NAMES = {}.freeze

    def self.captureless(input, start_position, finish_position, regexp)
      match_data = allocate
      value = input.byteslice(start_position, finish_position - start_position)
      match_data.instance_variable_set(:@values, [value].freeze)
      match_data.instance_variable_set(:@captures, EMPTY_CAPTURES)
      match_data.instance_variable_set(:@offsets, [[start_position, finish_position]].freeze)
      match_data.instance_variable_set(:@names, EMPTY_NAMES)
      match_data.instance_variable_set(:@string, input)
      match_data.instance_variable_set(:@regexp, regexp)
      match_data
    end

    def self.from_offsets(input, start_position, finish_position, capture_offsets, names, regexp)
      match_data = allocate
      full_match = input.byteslice(start_position, finish_position - start_position)
      captures = capture_offsets.map do |offset|
        offset && input.byteslice(offset[0], offset[1] - offset[0])
      end
      match_data.instance_variable_set(:@values, ([full_match] + captures).freeze)
      match_data.instance_variable_set(:@captures, captures.freeze)
      match_data.instance_variable_set(:@offsets, [[start_position, finish_position], *capture_offsets].freeze)
      match_data.instance_variable_set(:@names, names.freeze)
      match_data.instance_variable_set(:@string, input)
      match_data.instance_variable_set(:@regexp, regexp)
      match_data
    end

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

    def match(index)
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
        index.is_a?(Range) ? range_values(index) : [value_at(index)]
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
      details = inspect_names.map { |name, index| "#{name}:#{self[index].inspect}" }
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

    def inspect_names
      return @names.flat_map { |name, index| [[name, index]] } unless @regexp

      @regexp.named_captures.flat_map { |name, indices| indices.map { |index| [name, index] } }
    end

    def range_values(range)
      first = range_index(range.begin)
      last = range_index(range.end)
      last -= 1 if range.exclude_end?
      raise RangeError, "#{range} out of range" if first.negative?

      return [] if first > last

      (first..last).map { |index| value_at(index) }
    end

    def range_index(index)
      return index + @captures.length + 1 if index.is_a?(Integer) && index.negative?

      index
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
