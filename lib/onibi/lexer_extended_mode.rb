# frozen_string_literal: true

module Onibi
  # Skips extended-mode whitespace and top-level comments.
  module LexerExtendedMode
    private

    def extended_skip_index(index)
      return index unless @extended
      return index + 1 if extended_whitespace?(@source[index])
      return extended_comment_end(index) if @source[index] == "#"

      index
    end

    def extended_comment_end(index)
      @source.index("\n", index + 1) || @source.length
    end

    def extended_whitespace?(character)
      [" ", "\t", "\n", "\r", "\f", "\v"].include?(character)
    end
  end
end
