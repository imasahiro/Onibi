# frozen_string_literal: true

module Onibi
  # Fast replacement for the captureless linebreak alternation used by regex-redux.
  module RegexpLinebreakScanGsub
    private

    def hfa_linebreak_replace_api(input, replacement, block)
      return unless !block && replacement.index("\\").nil? && input.ascii_only?

      spec = hfa_linebreak_alternation_scan_spec
      return unless spec

      result = String.new(capacity: input.bytesize, encoding: input.encoding)
      cursor = 0
      position = 0
      while (newline = input.index("\n", position))
        marker = input.index(">", position)
        start = marker && marker < newline ? marker : newline
        finish = newline + 1
        result << input.byteslice(cursor, start - cursor) << replacement
        cursor = finish
        position = finish
      end
      result << input.byteslice(cursor, input.bytesize - cursor) if cursor < input.bytesize
      [result, input.bytesize]
    end
  end
end
