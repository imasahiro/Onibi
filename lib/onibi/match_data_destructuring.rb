# frozen_string_literal: true

module Onibi
  # Pattern-matching protocol for MatchData values.
  module MatchDataDestructuring
    def deconstruct
      captures
    end

    def deconstruct_keys(keys)
      return @names.each_with_object({}) do |(name, index), result|
        result[name.to_sym] = self[index]
      end unless keys

      keys.each_with_object({}) do |key, result|
        raise TypeError, "wrong argument type #{key.class} (expected Symbol)" unless key.is_a?(Symbol)

        name = key.to_s
        result[key] = self[name] if @names.key?(name)
      end
    end
  end
end
