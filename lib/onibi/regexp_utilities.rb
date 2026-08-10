# frozen_string_literal: true

module Onibi
  # Provides class-level regexp construction helpers.
  module RegexpUtilities
    def escape(string)
      source = string.is_a?(Symbol) ? string.to_s : String.try_convert(string)
      raise TypeError, "no implicit conversion of #{string.class} into String" unless source

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

    def linear_time?(pattern)
      source = compiled_pattern?(pattern) ? pattern.source : String.try_convert(pattern)
      raise TypeError, "no implicit conversion of #{pattern.class} into String" unless source

      unsafe_features = ["\\1", "\\2", "\\3", "\\k", "\\g", "(?=", "(?!", "(?<=", "(?<!", "(?>"]
      unsafe_features.none? { |feature| source.include?(feature) }
    end

    private

    def union_source(pattern)
      return scoped_union_source(pattern) if compiled_pattern?(pattern)

      escape(pattern)
    end

    def scoped_union_source(pattern)
      source = pattern.source
      return source unless (pattern.options & Onibi::Regexp::IGNORECASE).positive?

      "(?i:#{source})"
    end

    def compiled_pattern?(pattern)
      pattern.respond_to?(:source) && pattern.respond_to?(:options)
    end
  end
end
