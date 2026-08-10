# frozen_string_literal: true

module Onibi
  # Normalizes string and compiled regexp constructor inputs.
  module RegexpConstructorPatterns
    private

    def normalize_constructor_pattern(pattern, options)
      return [pattern.source, pattern.options] if pattern.is_a?(Regexp)

      [pattern, options]
    end
  end
end
