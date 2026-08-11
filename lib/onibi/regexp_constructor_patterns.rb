# frozen_string_literal: true

module Onibi
  # Normalizes string and compiled regexp constructor inputs.
  module RegexpConstructorPatterns
    private

    def normalize_constructor_pattern(pattern, options, timeout)
      if compiled_pattern?(pattern)
        inherited_timeout = timeout.nil? && pattern.respond_to?(:timeout) ? pattern.timeout : timeout
        return [pattern.source, pattern.options, inherited_timeout]
      end

      [pattern, options, timeout]
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
      store_pattern_options(pattern, normalized_options, options)
      [pattern, normalized_options]
    end
  end
end
