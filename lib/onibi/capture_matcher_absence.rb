# frozen_string_literal: true

module Onibi
  # Matches the longest prefix that avoids the next forbidden subexpression.
  module CaptureMatcherAbsence
    private

    def absence_results(node, characters, position, captures)
      occurrence = absence_occurrence(node.body, characters, position, captures)
      return [[characters.length, captures]] unless occurrence

      start, finish = occurrence
      limit = start >= position ? finish - 1 : finish
      limit >= position ? [[limit, captures]] : []
    end

    def absence_occurrence(body, characters, position, captures)
      (0...characters.length).each do |start|
        finish = match_results(body, characters, start, captures).map(&:first).select { |value| value > position }.min
        return [start, finish] if finish
      end
      nil
    end
  end
end
