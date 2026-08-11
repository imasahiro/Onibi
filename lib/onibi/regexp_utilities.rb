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

      escaped = source.each_char.each_with_object(source.dup.clear) do |character, result|
        result << escaped_character(character)
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
      patterns = patterns.first if patterns.length == 1 && patterns.first.is_a?(Array)
      source = patterns.empty? ? "(?!)" : patterns.map { |pattern| union_source(pattern) }.join("|")
      Onibi::Regexp.new(source, union_encoding_options(patterns))
    end

    def linear_time?(pattern)
      source = compiled_pattern?(pattern) ? pattern.source : String.try_convert(pattern)
      raise TypeError, "no implicit conversion of #{pattern.class} into String" unless source

      unsafe_features = ["\\1", "\\2", "\\3", "\\k", "\\g", "(?=", "(?!", "(?<=", "(?<!", "(?>", "(?~"]
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

      compiled_encoding_option(compiled)
    end

    def escaped_character(character)
      control = ESCAPED_CONTROL_CHARACTERS[character]
      return control if control

      special = "\\.^$*+?{}[]()|-# "
      special.include?(character) ? "\\#{character}" : character
    end

    def compiled_encoding_option(compiled)
      return Onibi::Regexp::NOENCODING if compiled.any? { |pattern| option_set?(pattern, Onibi::Regexp::NOENCODING) }
      if compiled.any? { |pattern| option_set?(pattern, Onibi::Regexp::FIXEDENCODING) }
        return Onibi::Regexp::FIXEDENCODING
      end

      0
    end

    def option_set?(pattern, option)
      (pattern.options & option).positive?
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
