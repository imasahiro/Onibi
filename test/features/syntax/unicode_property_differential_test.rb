# frozen_string_literal: true

require "test_helper"

class UnicodePropertyDifferentialTest < Minitest::Test
  CASES = [
    ["\\p{Alpha}", %w[A あ], %w[1]],
    ["\\P{Alpha}", %w[1], %w[A あ]],
    ["\\p{^Alpha}", %w[1], %w[A あ]],
    ["\\p{Hiragana}", ["あ"], ["ア"]],
    ["\\p{Katakana}", ["ア"], ["あ"]],
    ["\\p{Han}", %w[漢 𠀀], ["あ"]],
    ["\\p{Latin}", %w[A é ꝑ], ["Ж"]],
    ["\\p{Greek}", %w[Ω ἂ], ["A"]],
    ["\\p{Cyrillic}", %w[Ж Ꙁ], ["A"]],
    ["\\p{Arabic}", %w[ش ﻻ], ["A"]],
    ["\\p{Hiragana}", ["𛄀"], ["ア"]],
    ["\\p{Katakana}", ["𛀀"], ["あ"]],
    ["[[:digit:]]", %w[0 9], %w[a]],
    ["[[:alpha:]]", %w[A z], %w[1]],
    ["[[:ascii:]]", ["A"], ["あ"]],
    ["[[:word:]]", %w[A 0 _ ١ २ ０ \u0301], ["-"]],
    ["[[:space:]]", ["\u00a0", "\u2003", "\u2028"], ["A"]],
    ["[[:blank:]]", ["\u00a0", "\u2003"], ["A"]],
    ["[[:xdigit:]]", %w[0 9 a F], %w[١ g]],
    ["\\p{Alpha}", %w[A ͣ], %w[1]],
    ["\\p{Digit}", %w[0 ١ 𝟘], %w[²]],
    ["\\p{Alnum}", %w[A ١ 𝟘], %w[²]],
    ["\\p{Word}", %w[A ́ ١ ＿ ‌], %w[²]],
    ["\\p{Cntrl}", ["\u0000", "\u0085"], ["A"]],
    ["\\p{Graph}", ["A", "́", "​"], [" ", "\u0000"]],
    ["\\p{Print}", ["A", " ", " "], ["\u2028", "\u0000"]],
    ["\\p{L}", %w[A あ], %w[1 -]],
    ["\\p{M}", %w[́ ֑ ً ु], ["A"]],
    ["\\p{P}", ["-", "\u2014"], ["A"]],
    ["\\p{Z}", [" ", "\u2003"], ["A"]],
    ["\\p{N}", ["Ⅰ", "²", "①"], ["A"]],
    ["\\p{S}", ["©", "€"], ["A"]],
    ["\\p{Lu}", %w[A Ж], %w[a あ]],
    ["\\p{Ll}", %w[a ж], %w[A あ]],
    ["\\p{Lo}", %w[あ 漢], %w[A 1]],
    ["\\p{Cn}", ["\u0378", "\u{10ffff}"], %w[A あ]],
    ["\\p{Assigned}", %w[A あ], ["\u0378"]],
    ["\\p{White_Space}", [" ", "\u2003"], %w[A]],
    ["\\p{ASCII_Hex_Digit}", %w[0 9 A f], %w[g １]],
    ["\\p{Hex_Digit}", %w[0 9 A f １ Ｆ], %w[g あ]],
    ["\\p{Dash}", ["-", "‐", "−"], %w[A あ]],
    ["\\p{InBasic_Latin}", %w[A 7], %w[あ é]],
    ["\\p{InGreek_and_Coptic}", %w[α Ω], %w[A Ж]],
    ["\\p{InHiragana}", ["あ"], %w[ア A]],
    ["\\p{InEmoticons}", ["😀", "😎"], %w[A あ]],
    ["\\p{InMiscellaneous_Symbols}", ["☃", "☀"], %w[A 😀]],
    ["\\p{InDingbats}", ["✂", "✈"], %w[A ☃]],
    ["\\p{InMathematical_Operators}", ["∑", "∞"], %w[A ☃]],
    ["\\p{InGeometric_Shapes}", ["●", "◆"], %w[A ☃]],
    ["\\p{InLetterlike_Symbols}", ["℉", "ℵ"], %w[A ☃]],
    ["\\p{InCurrency_Symbols}", ["€", "₿"], %w[A ☃]],
    ["\\p{InGeneral_Punctuation}", ["—", "…"], %w[A €]],
    ["\\p{InCJK_Symbols_and_Punctuation}", ["、", "。"], %w[A あ]],
    ["\\p{InGreek_Extended}", %w[ἀ ά], %w[A Ж]],
    ["\\p{InLatin_Extended_Additional}", %w[Ḁ ẞ], %w[A Ж]],
    ["\\p{InLatin_Extended_C}", %w[Ⱡ Ɀ], %w[A Ж]],
    ["\\p{InLatin_Extended_D}", ["꜠", "ꟿ"], %w[A Ж]],
    ["\\p{InLatin_Extended_E}", %w[ꬰ ꭟ], %w[A Ж]],
    ["\\p{InSupplemental_Arrows_A}", ["⟰", "⟿"], %w[A ∑]],
    ["\\p{InSupplemental_Mathematical_Operators}", ["⨀", "⫷"], %w[A ∑]],
    ["\\p{InTransport_and_Map_Symbols}", ["🚀", "🛸"], %w[A 😀]],
    ["\\p{InEnclosed_Alphanumerics}", ["①", "ⓐ"], %w[A ²]],
    ["\\p{InEnclosed_Alphanumeric_Supplement}", %w[🄰 🅰], %w[A 😀]],
    ["\\p{InMathematical_Alphanumeric_Symbols}", %w[𝐀 𝛼], %w[A ∑]],
    ["\\p{InCJK_Compatibility_Ideographs}", %w[﨑 神], %w[A あ]],
    ["\\p{InCJK_Strokes}", ["㇐", "㇑"], %w[A あ]],
    ["\\p{InIdeographic_Description_Characters}", ["⿰", "⿻"], %w[A あ]],
    ["\\p{InCJK_Radicals_Supplement}", ["⺀", "⻳"], %w[A あ]],
    ["\\p{InKatakana_Phonetic_Extensions}", %w[ㇰ ㇱ], %w[A ア]],
    ["\\p{InKana_Supplement}", %w[𛀀 𛀁], %w[A あ]],
    ["\\p{InCJK_Unified_Ideographs_Extension_A}", %w[㐀 䶮], %w[A あ]],
    ["\\p{InCJK_Unified_Ideographs_Extension_B}", %w[𠀀 𪚥], %w[A あ]],
    ["\\p{InCJK_Unified_Ideographs_Extension_C}", %w[𪠀 𫜴], %w[A あ]],
    ["\\p{InCJK_Unified_Ideographs_Extension_D}", %w[𫝀 𫠝], %w[A あ]],
    ["\\p{InCJK_Unified_Ideographs_Extension_E}", ["𫠠", "𬺯"], %w[A あ]],
    ["\\p{InCJK_Unified_Ideographs_Extension_F}", %w[𬺰 𮯯], %w[A あ]],
    ["\\p{InCJK_Unified_Ideographs_Extension_G}", ["𰀀", "𱍏"], %w[A あ]],
    ["\\p{InCJK_Unified_Ideographs_Extension_H}", %w[𱍐 𲎯], %w[A あ]],
    ["\\p{InCJK_Unified_Ideographs_Extension_I}", %w[𮯰 𮹟], %w[A あ]],
    ["\\p{InCJK_Unified_Ideographs_Extension_J}", %w[𲎰 𳑿], %w[A あ]],
    ["\\p{InVertical_Forms}", %w[︐ ︟], %w[A あ]],
    ["\\p{InNKo}", ["߀", "߷"], %w[A あ]],
    ["\\p{InCoptic}", ["Ⲁ", "⳹"], %w[A α]],
    ["\\p{InCyrillic_Extended_C}", %w[ᲀ ᲏], %w[A Ж]],
    ["\\p{InCyrillic_Extended_D}", %w[𞀰 𞂏], %w[A Ж]],
    ["\\p{InGeorgian_Extended}", %w[Ა Ჿ], %w[A Ж]],
    ["\\p{InArabic_Presentation_Forms_A}", %w[ﭐ ﷲ], %w[A ش]],
    ["\\p{InArabic_Presentation_Forms_B}", %w[ﹰ ﹶ], %w[A ش]],
    ["\\N{SNOWMAN}", ["N{SNOWMAN}"], ["☃", "A"]],
    ["\\Qabc\\E", ["QabcE"], ["abc", "\\Qabc\\E"]],
    ["[\\N{SNOWMAN}]", ["N"], ["☃", "x"]]
  ].freeze

  def test_unicode_and_posix_property_corpus_matches_mri
    CASES.each do |pattern, matching_inputs, non_matching_inputs|
      matching_inputs.each { |input| assert_same_outcome(pattern, input, true) }
      non_matching_inputs.each { |input| assert_same_outcome(pattern, input, false) }
    end
  end

  def test_invalid_unicode_property_errors_match_mri
    assert_equal :error, outcome(Regexp, "\\p{NoSuchProperty}", "x")
    assert_equal :error, outcome(Onibi::Regexp, "\\p{NoSuchProperty}", "x")
    assert_equal :error, outcome(Regexp, "\\p{IsLatin}", "x")
    assert_equal :error, outcome(Onibi::Regexp, "\\p{IsLatin}", "x")
  end

  private

  def assert_same_outcome(pattern, input, expected)
    mri = outcome(Regexp, pattern, input)
    onibi = outcome(Onibi::Regexp, pattern, input)

    assert_equal expected, mri, "MRI outcome for #{pattern.inspect} / #{input.inspect}"
    assert_equal mri, onibi, "Onibi outcome for #{pattern.inspect} / #{input.inspect}"
  end

  def outcome(regexp_class, pattern, input)
    regexp_class.new(pattern).match?(input) || false
  rescue StandardError
    :error
  end
end
