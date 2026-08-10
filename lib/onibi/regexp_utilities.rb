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

    def union(*patterns)
      source = patterns.empty? ? "(?!)" : patterns.map { |pattern| union_source(pattern) }.join("|")
      Onibi::Regexp.new(source)
    end

    private

    def union_source(pattern)
      return pattern.source if compiled_pattern?(pattern)

      escape(pattern)
    end

    def compiled_pattern?(pattern)
      pattern.respond_to?(:source) && pattern.respond_to?(:options)
    end
  end
end
