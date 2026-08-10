# frozen_string_literal: true

module Onibi
  # Matches Unicode script and block ranges used by property dispatch.
  module UnicodePropertyScripts
    def ascii?(character)
      character.codepoints.first <= 127
    end

    def any?(_character)
      true
    end

    def han?(character)
      character.codepoints.first.between?(0x4E00, 0x9FFF)
    end

    def hiragana?(character)
      character.codepoints.first.between?(0x3040, 0x309F)
    end

    def katakana?(character)
      character.codepoints.first.between?(0x30A0, 0x30FF)
    end

    def latin?(character)
      character.codepoints.first <= 0x024F && letter?(character)
    end

    def greek?(character)
      character.codepoints.first.between?(0x0370, 0x03FF)
    end

    def cyrillic?(character)
      character.codepoints.first.between?(0x0400, 0x04FF)
    end

    def arabic?(character)
      character.codepoints.first.between?(0x0600, 0x06FF)
    end
  end
end
