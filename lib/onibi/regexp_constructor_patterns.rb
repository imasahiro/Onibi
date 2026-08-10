# frozen_string_literal: true

module Onibi
  # Normalizes string and compiled regexp constructor inputs.
  module RegexpConstructorPatterns
    private

    def normalize_constructor_pattern(pattern, options)
      return [pattern.source, pattern.options] if compiled_pattern?(pattern)

      [pattern, options]
    end

    def compiled_pattern?(pattern)
      pattern.respond_to?(:source) && pattern.respond_to?(:options)
    end

    def prepare_constructor_pattern(pattern, options)
      validate_pattern_type!(pattern)
      validate_pattern_encoding!(pattern)
      @source_pattern = pattern
      normalized_options = normalize_options(options)
      pattern, normalized_options = normalize_inline_modifier(pattern, normalized_options)
      validate_noencoding_pattern!(pattern, normalized_options)
      validate_pattern_syntax!(pattern, normalized_options)
      store_pattern_options(pattern, normalized_options, options)
      [pattern, normalized_options]
    end
  end
end
