# frozen_string_literal: true

module Onibi
  # Provides class-level regexp construction helpers.
  module RegexpUtilities
    def escape(string)
      source = string.to_s
      special = "\\.^$*+?{}[]()|# "
      source.each_char.each_with_object(source.dup.clear) do |character, escaped|
        escaped << "\\" if special.include?(character)
        escaped << character
      end
    end
  end
end
