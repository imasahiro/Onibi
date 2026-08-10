# frozen_string_literal: true

module Onibi
  module MatchDataDestructuring
    def deconstruct
      to_a
    end

    def deconstruct_keys(keys)
      return named_captures unless keys

      keys.each_with_object({}) do |key, result|
        name = key.to_s
        result[name] = self[name] if @names.key?(name)
      end
    end
  end
end
