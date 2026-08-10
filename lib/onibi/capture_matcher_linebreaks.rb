# frozen_string_literal: true

module Onibi
  # Matches Ruby linebreak escape sequences while preserving captures.
  module CaptureMatcherLinebreaks
    private

    def linebreak_results(characters, position, captures)
      return [] unless position < characters.length && CharacterPredicates.linebreak?(characters[position])
      return [[position + 2, captures]] if characters[position, 2] == ["\r", "\n"]

      [[position + 1, captures]]
    end
  end
end
