# frozen_string_literal: true

module Onibi
  # Provides MatchData character and byte offset accessors.
  module MatchDataOffsets
    def offset(index)
      offset_at(index) || [nil, nil]
    end

    def begin(index)
      offset_at(index)&.first
    end

    def end(index)
      offset_at(index)&.last
    end

    def bytebegin(index)
      offset = offset_at(index)
      offset && byte_position(offset.first)
    end

    def byteend(index)
      offset = offset_at(index)
      offset && byte_position(offset.last)
    end

    def byteoffset(index)
      [bytebegin(index), byteend(index)]
    end

    def match_length(index)
      offset = offset_at(index)
      return nil unless offset

      offset.last - offset.first
    end

    private

    def offset_at(index)
      index = named_index(index)
      validate_offset_index!(index)
      @offsets[index]
    end

    def named_index(index)
      if index.is_a?(String) || index.is_a?(Symbol)
        value = @names[index.to_s]
        raise IndexError, "undefined group name reference: #{index}" if value.nil?

        return value.reverse.find { |candidate| @values[candidate] } || value.last if value.is_a?(Array)

        return value
      end

      index
    end

    def validate_offset_index!(index)
      raise TypeError, "no implicit conversion from #{index.class} into integer" unless index.is_a?(Integer)
      raise IndexError, "index #{index} out of matches" if index.negative? || index >= @offsets.length
    end

    def byte_position(character_position)
      prefix = String.instance_method(:[]).bind_call(@string, 0, character_position)
      String.instance_method(:bytesize).bind_call(prefix)
    end
  end
end
