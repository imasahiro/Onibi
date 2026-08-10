# frozen_string_literal: true

module Onibi
  # Provides class-level regexp construction helpers.
  module RegexpUtilities
    ESCAPED_CONTROL_CHARACTERS = {
      "\t" => "\\t", "\n" => "\\n", "\v" => "\\v", "\f" => "\\f", "\r" => "\\r"
    }.freeze

    def escape(string)
      source = string.is_a?(Symbol) ? string.to_s : String.try_convert(string)
      raise TypeError, "no implicit conversion of #{string.class} into String" unless source

      special = "\\.^$*+?{}[]()|-# "
      escaped = source.each_char.each_with_object(source.dup.clear) do |character, result|
        control = ESCAPED_CONTROL_CHARACTERS[character]
        if control
          result << control
          next
        end
        result << "\\" if special.include?(character)
        result << character
      end
      source.ascii_only? ? escaped.force_encoding(Encoding::US_ASCII) : escaped
    end

    alias quote escape

    def try_convert(value)
      return value if value.is_a?(self)
      return nil unless value.respond_to?(:to_regexp)

      converted = value.to_regexp
      return converted if converted.is_a?(self)

      raise TypeError, "can't convert #{value.class} to Regexp (to_regexp did not return Regexp)"
    end

    def union(*patterns)
      source = patterns.empty? ? "(?!)" : patterns.map { |pattern| union_source(pattern) }.join("|")
      Onibi::Regexp.new(source, union_encoding_options(patterns))
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
      options = pattern.options
      source = "(?i:#{source})" if (options & Onibi::Regexp::IGNORECASE).positive?
      source = "(?m:#{source})" if (options & Onibi::Regexp::MULTILINE).positive?
      source = "(?x:#{source})" if (options & Onibi::Regexp::EXTENDED).positive?

      source
    end

    def union_encoding_options(patterns)
      return Onibi::Regexp::FIXEDENCODING if patterns.any? { |pattern| non_ascii_pattern?(pattern) }

      compiled = patterns.select { |pattern| compiled_pattern?(pattern) }
      return 0 if compiled.length < patterns.length
      return 0 if compiled.empty?
      return Onibi::Regexp::NOENCODING if compiled.any? { |pattern| (pattern.options & Onibi::Regexp::NOENCODING).positive? }
      return Onibi::Regexp::FIXEDENCODING if compiled.any? { |pattern| (pattern.options & Onibi::Regexp::FIXEDENCODING).positive? }

      0
    end

    def non_ascii_pattern?(pattern)
      source = compiled_pattern?(pattern) ? pattern.source : String.try_convert(pattern)
      source && !source.ascii_only?
    end

    def compiled_pattern?(pattern)
      pattern.respond_to?(:source) && pattern.respond_to?(:options)
    end
  end
end
