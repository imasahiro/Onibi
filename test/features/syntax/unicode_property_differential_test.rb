# frozen_string_literal: true

require "test_helper"

class UnicodePropertyDifferentialTest < Minitest::Test
  CASES = [
    ["\\p{Alpha}", %w[A あ], %w[1]],
    ["\\p{Alphabetic}", %w[A あ Ω], %w[1 😀]],
    ["\\p{Decimal_Number}", %w[0 ٩ 𝟘], %w[A ²]],
    ["\\p{Lowercase}", %w[a z], %w[A 1]],
    ["\\p{Uppercase}", %w[A Z], %w[a 1]],
    ["\\p{Punctuation}", [".", "!", "、"], %w[A 1]],
    ["\\P{Alpha}", %w[1], %w[A あ]],
    ["\\p{^Alpha}", %w[1], %w[A あ]],
    ["\\p{Hiragana}", ["あ"], ["ア"]],
    ["\\p{hiragana}", ["あ"], ["ア"]],
    ["\\p{HIRAGANA}", ["あ"], ["ア"]],
    ["\\p{ASCII-Hex-Digit}", %w[0 A f], %w[g あ]],
    ["\\p{ASCIIHexDigit}", %w[0 A f], %w[g あ]],
    ["\\p{Katakana}", ["ア"], ["あ"]],
    ["\\p{Emoji}", %w[# © 😀 🇯🇵], %w[A あ]],
    ["\\p{Emoji_Presentation}", %w[😀 🚀], %w[A # ©]],
    ["\\p{Emoji_Modifier}", ["🏻", "🏿"], %w[A 😀]],
    ["\\p{Emoji_Modifier_Base}", ["👍", "🧑"], %w[A 😀]],
    ["\\p{Extended_Pictographic}", %w[© 😀 🀄], %w[A あ]],
    ["\\p{Bidi_Control}", ["\u061c", "\u200e", "\u202e"], %w[A あ]],
    ["\\p{Case_Ignorable}", ["'", "\u0301", "\u200c"], %w[A あ]],
    ["\\p{Default_Ignorable_Code_Point}", ["\u00ad", "\u200b", "\ufe0f"], %w[A あ]],
    ["\\p{Deprecated}", ["\u0149", "\u0673", "\u0f77", "\u0f79", "\u17a3", "\u206a", "\u2329", "\u{e0001}"], %w[A あ 😀]],
    ["\\p{Diacritic}", ["^", "\u0301", "\u05b0", "\u1ab0", "\u1ab5"], %w[A あ 😀]],
    ["\\p{Emoji_Component}", ["#", "0", "\u200d", "\ufe0f", "🇯"], %w[A あ 😀]],
    ["\\p{Join_Control}", %w[‌ ‍], %w[A あ 😀]],
    ["\\p{Regional_Indicator}", ["🇯", "🇵"], %w[A あ 😀]],
    ["\\p{Variation_Selector}", %w[️ ︎ 󠄀], %w[A あ 😀]],
    ["\\p{Noncharacter_Code_Point}", ["\ufffe", "\uffff", "\u{fdd0}", "\u{10ffff}"], %w[A あ 😀]],
    ["\\p{Pattern_White_Space}", ["\t", "\n", " ", "\u0085", "\u200e"], %w[A あ 😀]],
    ["\\p{Quotation_Mark}", ["\"", "'", "«", "“", "「"], %w[A あ 😀]],
    ["\\p{Terminal_Punctuation}", [".", "!", "?", "。", "؟"], %w[A あ 😀]],
    ["\\p{Soft_Dotted}", %w[i j į 𝐢], %w[A あ 😀]],
    ["\\p{Extender}", ["·", "ـ", "々", "ー", "\u{a60c}"], %w[A あ 😀]],
    ["\\p{Math}", ["+", "<", "∑", "∞", "𝑖"], %w[A あ 😀]],
    ["\\p{Cased}", %w[A a Ω Ж], %w[1 あ 😀]],
    ["\\p{Sentence_Terminal}", [".", "!", "?", "。", "؟"], %w[A あ 😀]],
    ["\\p{Prepended_Concatenation_Mark}", ["\u0600", "\u0601", "\u06dd"], %w[A あ 😀]],
    ["\\p{Ideographic}", %w[一 漢 𠀀], %w[A あ 😀]],
    ["\\p{Unified_Ideograph}", %w[一 漢 𠀀], %w[A あ 😀]],
    ["\\p{ID_Compat_Math_Start}", ["∂", "∇", "∞"], %w[A あ 😀]],
    ["\\p{ID_Compat_Math_Continue}", ["²", "⁴", "∂", "∞"], %w[A あ 😀]],
    ["\\p{Grapheme_Extend}", %w[́ ⃝ 󠄀], %w[A あ 😀]],
    ["\\p{Grapheme_Base}", %w[A あ 一 😀], ["\u0301"]],
    ["\\p{ID_Start}", %w[A Ω Ж 漢], %w[1 😀]],
    ["\\p{ID_Continue}", %w[A 1 _ ́ 漢], %w[😀]],
    ["\\p{XID_Start}", %w[A Ω Ж 漢], %w[1 😀]],
    ["\\p{XID_Continue}", %w[A 1 _ ́ 漢], %w[😀]],
    ["\\p{Changes_When_Casefolded}", %w[A Ω Ж], %w[1 あ 😀]],
    ["\\p{Changes_When_Casemapped}", %w[A Ω Ж], %w[1 あ 😀]],
    ["\\p{Changes_When_Lowercased}", %w[A Ω Ж], %w[1 あ 😀]],
    ["\\p{Changes_When_Uppercased}", %w[a ω ж], %w[1 あ 😀]],
    ["\\p{Changes_When_Titlecased}", %w[a ω ж], %w[1 あ 😀]],
    ["\\p{Pattern_Syntax}", ["!", "[", "~", "→", "⟨"], %w[A あ 😀]],
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
    ["\\p{Lu}", ["\u{1D400}"], ["\u{1F187}"]],
    ["\\p{Ll}", %w[a ж], %w[A あ]],
    ["\\p{Ll}", %W[\u{AB60} \u{AB68}], %W[\u{AB5C} \u{AB5D} \u{AB5E} \u{AB5F} \u{AB69}]],
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
    ["\\p{inhiragana}", ["あ"], %w[ア A]],
    ["\\p{InBasicLatin}", %w[A 7], %w[あ é]],
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
    ["\\p{InLatin_Extended_F}", %w[𐞀 𐞁], %w[A Ж]],
    ["\\p{InLatin_Extended_G}", ["\u{1DF00}", "\u{1DFFF}"], %w[A Ж]],
    ["\\p{InSupplemental_Arrows_A}", ["⟰", "⟿"], %w[A ∑]],
    ["\\p{InSupplemental_Mathematical_Operators}", ["⨀", "⫷"], %w[A ∑]],
    ["\\p{InTransport_and_Map_Symbols}", ["🚀", "🛸"], %w[A 😀]],
    ["\\p{InEnclosed_Alphanumerics}", ["①", "ⓐ"], %w[A ²]],
    ["\\p{InEnclosed_Alphanumeric_Supplement}", %w[🄰 🅰], %w[A 😀]],
    ["\\p{InMathematical_Alphanumeric_Symbols}", %w[𝐀 𝛼], %w[A ∑]],
    ["\\p{InCJK_Compatibility_Ideographs}", %w[﨑 神], %w[A あ]],
    ["\\p{InCJK_Compatibility_Ideographs_Supplement}", ["丽", "𯨟"], %w[A あ]],
    ["\\p{InKawi}", ["\u{11F00}", "\u{11F5F}"], %w[A あ]],
    ["\\p{InNag_Mundari}", ["\u{1E4D0}", "\u{1E4FF}"], %w[A अ]],
    ["\\p{InOl_Onal}", ["\u{1E5D0}", "\u{1E5FF}"], %w[A अ]],
    ["\\p{InTangsa}", ["\u{16A70}", "\u{16ACF}"], %w[A अ]],
    ["\\p{InWancho}", ["\u{1E2C0}", "\u{1E2FF}"], %w[A अ]],
    ["\\p{InToto}", ["\u{1E290}", "\u{1E2BF}"], %w[A अ]],
    ["\\p{InAdlam}", ["\u{1E900}", "\u{1E95F}"], %w[A अ]],
    ["\\p{InMedefaidrin}", ["\u{16E40}", "\u{16E9F}"], %w[A अ]],
    ["\\p{InMende_Kikakui}", ["\u{1E800}", "\u{1E8DF}"], %w[A अ]],
    ["\\p{InNyiakeng_Puachue_Hmong}", ["\u{1E100}", "\u{1E14F}"], %w[A अ]],
    ["\\p{InBassa_Vah}", ["\u{16AD0}", "\u{16AFF}"], %w[A अ]],
    ["\\p{InMiao}", %w[𖼀 𖾟], %w[A अ]],
    ["\\p{InBamum_Supplement}", ["𖠀", "𖨿"], %w[A अ]],
    ["\\p{InPahawh_Hmong}", %w[𖬀 𖮏], %w[A अ]],
    ["\\p{InMakasar}", ["𑻠", "\u{11EFF}"], %w[A अ]],
    ["\\p{InBamum}", ["ꚠ", "꛿"], %w[A अ]],
    ["\\p{InSundanese_Supplement}", ["᳀", "᳏"], %w[A अ]],
    ["\\p{InBatak}", ["ᯀ", "᯿"], %w[A अ]],
    ["\\p{InLisu}", %w[ꓐ ꓸ], %w[A अ]],
    ["\\p{InOl_Chiki}", ["᱐", "᱿"], %w[A अ]],
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
    ["\\p{InCyrillic_Extended_A}", %w[ⷠ ⷿ], %w[A Ж]],
    ["\\p{InCyrillic_Extended_B}", %w[Ꙁ ꚟ], %w[A Ж]],
    ["\\p{InCyrillic_Extended_D}", %w[𞀰 𞂏], %w[A Ж]],
    ["\\p{InGeorgian_Extended}", %w[Ა Ჿ], %w[A Ж]],
    ["\\p{InArabic_Presentation_Forms_A}", %w[ﭐ ﷲ], %w[A ش]],
    ["\\p{InArabic_Extended_A}", %w[ࢠ ࣿ], %w[A ش]],
    ["\\p{InArabic_Extended_B}", %w[ࡰ ࢟], %w[A ش]],
    ["\\p{InArabic_Extended_C}", ["𐻀", "𐻿"], %w[A ش]],
    ["\\p{InArabic_Mathematical_Alphabetic_Symbols}", ["𞸀", "𞹿"], %w[A ش]],
    ["\\p{InDevanagari_Extended}", %w[꣠ ꣿ], %w[A अ]],
    ["\\p{InDevanagari_Extended_A}", ["𑬀", "𑭟"], %w[A अ]],
    ["\\p{InKana_Extended_A}", ["\u{1B100}", "\u{1B12F}"], %w[A あ]],
    ["\\p{InKana_Extended_B}", ["\u{1AFF0}", "\u{1AFFF}"], %w[A あ]],
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

  def test_ignorecase_general_categories_match_both_letter_cases
    [["\\p{Ll}", "A", true], ["\\p{Lu}", "a", true],
     ["\\p{Ll}", "ǅ", true], ["\\p{Lu}", "ı", false],
     ["\\p{Greek}", "ͅ", true], ["\\p{Upper}", "ß", true],
     ["\\p{Upper}", "ꝷ", false],
     ["[\\p{Ll}]", "É", true], ["[\\p{Lu}]", "é", true]].each do |pattern, input, expected|
      assert_same_outcome(pattern, input, expected, Regexp::IGNORECASE)
    end

    [["[\\P{Ll}]", "a"], ["[\\P{Lu}]", "A"]].each do |pattern, input|
      assert_same_outcome(pattern, input, true, Regexp::IGNORECASE)
    end
  end

  def test_ignorecase_property_can_use_a_multi_character_fold_before_an_anchor
    pattern = "\\p{Lu}\\b"
    mri = Regexp.new(pattern, Regexp::IGNORECASE).match("SS")
    onibi = Onibi::Regexp.new(pattern, Regexp::IGNORECASE).match("SS")

    assert_equal ["SS", [0, 2]], [mri[0], mri.offset(0)]
    assert_equal [mri[0], mri.offset(0)], [onibi[0], onibi.offset(0)]
  end

  def test_ignorecase_upper_posix_class_does_not_accept_expanding_lower_fold
    pattern = "[[:upper:]]+"
    %w[ᾀ ᾳ ß A].each do |input|
      mri = Regexp.new(pattern, Regexp::IGNORECASE).match(input)
      onibi = Onibi::Regexp.new(pattern, Onibi::Regexp::IGNORECASE).match(input)

      assert_equal [mri&.[](0), mri&.offset(0)], [onibi&.[](0), onibi&.offset(0)]
    end
  end

  def test_ignorecase_bare_negated_property_uses_casefold_closure
    pattern = "\\P{Ll}\\z"
    mri = Regexp.new(pattern, Regexp::IGNORECASE).match("SS")
    onibi = Onibi::Regexp.new(pattern, Regexp::IGNORECASE).match("SS")

    assert_nil mri
    assert_nil onibi
  end

  def test_ignorecase_literal_runs_use_multi_character_fold_closure
    [
      %w[ſss ßſ],
      %w[SSς ßς]
    ].each do |pattern, input|
      mri = Regexp.new(pattern, Regexp::IGNORECASE).match(input)
      onibi = Onibi::Regexp.new(pattern, Onibi::Regexp::IGNORECASE).match(input)

      assert_equal [mri[0], mri.offset(0)], [onibi[0], onibi.offset(0)]
    end
  end

  def test_ignorecase_literal_run_preserves_multi_fold_node_boundaries
    pattern = "ſẞ"
    input = "ßs"
    mri = Regexp.new(pattern).match(input)
    onibi = Onibi::Regexp.new(pattern).match(input)

    assert_nil mri
    assert_nil onibi
  end

  def test_ignorecase_fixed_literal_quantifier_can_use_a_reverse_fold
    pattern = "ſ{2}"
    input = "ß"
    mri = Regexp.new(pattern, Regexp::IGNORECASE).match(input)
    onibi = Onibi::Regexp.new(pattern, Onibi::Regexp::IGNORECASE).match(input)

    assert_equal [mri[0], mri.offset(0)], [onibi[0], onibi.offset(0)]
  end

  def test_ignorecase_optional_fold_preserves_mri_branch_order
    [
      %w[s?a ſa],
      %w[s? ſ],
      %w[s?ß ſẞ],
      %w[s?ß+ ſẞ],
      %w[É?ß*ß* éſſἀbς]
    ].each do |pattern, input|
      mri = Regexp.new(pattern, Regexp::IGNORECASE).match(input)
      onibi = Onibi::Regexp.new(pattern, Onibi::Regexp::IGNORECASE).match(input)

      assert_equal [mri[0], mri.offset(0)], [onibi[0], onibi.offset(0)]
    end
  end

  def test_ignorecase_fixed_character_class_quantifier_can_split_a_reverse_fold
    [
      %w[[s]{2} ß],
      %w[[ſ]{2} ß],
      %w[[ß]{2} ß],
      %w[[ß]{2} sßs]
    ].each do |pattern, input|
      mri = Regexp.new(pattern, Regexp::IGNORECASE).match(input)
      onibi = Onibi::Regexp.new(pattern, Onibi::Regexp::IGNORECASE).match(input)

      assert_equal [mri&.[](0), mri&.offset(0)], [onibi&.[](0), onibi&.offset(0)]
    end
  end

  def test_ignorecase_property_quantifier_keeps_codepoint_repetition
    [
      %w[[[:alpha:]]{2} ᾀa],
      %w[ᾀb+ ᾀb]
    ].each do |pattern, input|
      mri = Regexp.new(pattern, Regexp::IGNORECASE).match(input)
      onibi = Onibi::Regexp.new(pattern, Onibi::Regexp::IGNORECASE).match(input)

      assert_equal [mri&.[](0), mri&.offset(0)], [onibi&.[](0), onibi&.offset(0)]
    end
  end

  def test_ignorecase_greek_fold_quantifier_preserves_operand_boundaries
    [
      %w[ᾀ{1,2}b ᾀb],
      %w[s?ᾀ{1,2}[s]{2} ςÉbbᾀß]
    ].each do |pattern, input|
      mri = Regexp.new(pattern, Regexp::IGNORECASE).match(input)
      onibi = Onibi::Regexp.new(pattern, Onibi::Regexp::IGNORECASE).match(input)

      assert_equal [mri&.[](0), mri&.offset(0)], [onibi&.[](0), onibi&.offset(0)]
    end
  end

  def test_ignorecase_greek_fold_boundary_keeps_later_bounded_fold_candidate
    pattern = "ᾀ*ᾀÉ{1,2}"
    %w[ᾀÉ ᾀÉaéb].each do |input|
      mri = Regexp.new(pattern, Regexp::IGNORECASE).match(input)
      onibi = Onibi::Regexp.new(pattern, Onibi::Regexp::IGNORECASE).match(input)

      assert_equal [mri&.[](0), mri&.offset(0)], [onibi&.[](0), onibi&.offset(0)]
    end
  end

  def test_ignorecase_greek_fold_boundary_does_not_use_a_distant_candidate_alone
    pattern = "ᾀἀ{1,2}"
    input = "ᾀἀιéἀιSſ"
    mri = Regexp.new(pattern, Regexp::IGNORECASE).match(input)
    onibi = Onibi::Regexp.new(pattern, Onibi::Regexp::IGNORECASE).match(input)

    assert_nil mri
    assert_nil onibi
  end

  def test_ignorecase_greek_fold_quantifier_can_be_followed_by_a_class
    pattern = "ᾀ{1,2}[s]+"
    input = "ᾀssßÉSS"
    mri = Regexp.new(pattern, Regexp::IGNORECASE).match(input)
    onibi = Onibi::Regexp.new(pattern, Onibi::Regexp::IGNORECASE).match(input)

    assert_equal [mri[0], mri.offset(0)], [onibi[0], onibi.offset(0)]
  end

  def test_ignorecase_class_fold_alternate_preserves_following_quantifier_boundary
    pattern = "[ſ]{1,2}ι{1,2}"
    input = "sſιSιe"
    mri = Regexp.new(pattern, Regexp::IGNORECASE).match(input)
    onibi = Onibi::Regexp.new(pattern, Onibi::Regexp::IGNORECASE).match(input)

    assert_equal [mri[0], mri.offset(0)], [onibi[0], onibi.offset(0)]
  end

  def test_ignorecase_optional_fold_precedes_a_bounded_same_fold_class
    pattern = "ſ?[s]{1,2}ß{1,2}"
    input = "éſſSSS"
    mri = Regexp.new(pattern, Regexp::IGNORECASE).match(input)
    onibi = Onibi::Regexp.new(pattern, Onibi::Regexp::IGNORECASE).match(input)

    assert_equal [mri[0], mri.offset(0)], [onibi[0], onibi.offset(0)]
  end

  def test_ignorecase_optional_fold_precedes_an_expanding_class
    pattern = "ſ?[ß]ᾀ?"
    input = "éſſSSS"
    mri = Regexp.new(pattern, Regexp::IGNORECASE).match(input)
    onibi = Onibi::Regexp.new(pattern, Onibi::Regexp::IGNORECASE).match(input)

    assert_equal [mri[0], mri.offset(0)], [onibi[0], onibi.offset(0)]
  end

  def test_ignorecase_class_and_literal_can_join_expanding_fold_sequences
    pattern = "[ß]ẞἀ+"
    input = "sẞSἀιᾀÉ"
    mri = Regexp.new(pattern, Regexp::IGNORECASE).match(input)
    onibi = Onibi::Regexp.new(pattern, Onibi::Regexp::IGNORECASE).match(input)

    assert_equal [mri[0], mri.offset(0)], [onibi[0], onibi.offset(0)]
  end

  def test_ignorecase_expanding_literal_does_not_start_inside_a_prior_fold
    pattern = "(?i:[s]ß)"
    input = "ßss"
    mri = Regexp.new(pattern).match(input)
    onibi = Onibi::Regexp.new(pattern).match(input)

    assert_nil mri
    assert_nil onibi
  end

  def test_ignorecase_literal_prefix_accepts_a_reverse_greek_fold
    ["ᾀ(?:ᾀ)", "ἀιἀι"].each do |pattern|
      input = "ᾀἀι"
      mri = Regexp.new(pattern, Regexp::IGNORECASE).match(input)
      onibi = Onibi::Regexp.new(pattern, Onibi::Regexp::IGNORECASE).match(input)

      assert_equal [mri&.[](0), mri&.offset(0)], [onibi&.[](0), onibi&.offset(0)]
    end

    pattern = "ᾀ(?:ἀι)"
    input = "ᾀᾀ"
    mri = Regexp.new(pattern, Regexp::IGNORECASE).match(input)
    onibi = Onibi::Regexp.new(pattern, Onibi::Regexp::IGNORECASE).match(input)

    assert_nil mri
    assert_nil onibi
  end

  def test_ignorecase_fold_branch_can_fall_through_to_zero_width_alternative
    pattern = "(?:(?i:ᾀ)|(?!b))"
    ["", "b", "bb"].each do |input|
      mri = Regexp.new(pattern).match(input)
      onibi = Onibi::Regexp.new(pattern).match(input)

      assert_equal [mri[0], mri.offset(0)], [onibi[0], onibi.offset(0)]
    end
  end

  def test_expanding_literal_group_does_not_change_non_ignorecase_execution
    ["(?:ᾀ)(?!b)(?!b)", "(?:ß)(?>(?!b))"].each do |pattern|
      input = pattern.include?("ᾀ") ? "ᾀἀι" : "ß"
      mri = Regexp.new(pattern).match(input)
      onibi = Onibi::Regexp.new(pattern).match(input)

      assert_equal [mri[0], mri.offset(0)], [onibi[0], onibi.offset(0)]
    end
  end

  def test_scoped_ignorecase_fold_preserves_following_group_boundary
    pattern = "(?i:ᾀ)(?:ἀι)"
    input = "ᾀἀι"
    mri = Regexp.new(pattern).match(input)
    onibi = Onibi::Regexp.new(pattern).match(input)

    assert_nil mri
    assert_nil onibi
  end

  def test_scoped_ignorecase_latin_fold_can_continue_with_a_repeated_tail
    pattern = "(?i:ß)(?:s)"
    input = "ßs"
    mri = Regexp.new(pattern).match(input)
    onibi = Onibi::Regexp.new(pattern).match(input)

    assert_equal [mri[0], mri.offset(0)], [onibi[0], onibi.offset(0)]
  end

  def test_scoped_ignorecase_greek_fold_respects_strict_end_anchor
    %w[ᾀ ᾷ ῇ ῷ].each do |input|
      pattern = "(?i:#{input}){1,2}\\z"
      mri = Regexp.new(pattern).match(input)
      onibi = Onibi::Regexp.new(pattern).match(input)

      assert_nil mri
      assert_nil onibi
    end
  end

  def test_scoped_ignorecase_class_fold_preserves_operand_boundaries
    [
      ["(?i:[ᾀ]){1,2}\\z", "ᾀἀι"],
      ["(?i:[ᾀ])(?:ἀι)", "ᾀἀι"],
      ["(?i:[ᾀ])(?:ᾀ)", "ᾀᾀ"]
    ].each do |pattern, input|
      mri = Regexp.new(pattern).match(input)
      onibi = Onibi::Regexp.new(pattern).match(input)

      assert_equal [mri&.[](0), mri&.offset(0)], [onibi&.[](0), onibi&.offset(0)]
    end
  end

  def test_expanded_fold_prefix_can_continue_with_a_literal
    %w[İ ŉ ΐ ẖ].each do |source|
      folded = source.downcase(:fold)
      pattern = "(?i:[#{source}])#{folded.each_char.first}"
      input = source + folded

      assert_equal Regexp.new(pattern).match?(input), Onibi::Regexp.new(pattern).match?(input)
    end

    pattern = "(?i:[ᾀ])(?=ἀ)"
    input = "ᾀἀι"
    assert_equal Regexp.new(pattern).match?(input), Onibi::Regexp.new(pattern).match?(input)
  end

  def test_iota_fold_does_not_split_into_following_operands
    [["(?i:ᾀ)ἀ", "ᾀἀι"], ["(?i:ᾀ)(?:ἀ)", "ᾀἀι"],
     ["(?i:ᾀ)(?=ἀ)", "ᾀἀι"], ["(?i:ᾴ)(?=ά)", "ᾴάι"],
     ["(?i:ῳ)(?=ω)", "ῳωι"]].each do |pattern, input|
      assert_equal Regexp.new(pattern).match?(input), Onibi::Regexp.new(pattern).match?(input)
    end

    pattern = "(?i:(ᾀ))ἀ"
    input = "ᾀἀι"
    assert_equal Regexp.new(pattern).match?(input), Onibi::Regexp.new(pattern).match?(input)

    pattern = "(?i:ᾀ)ι\\z"
    input = "ᾀι"
    assert_equal Regexp.new(pattern).match?(input), Onibi::Regexp.new(pattern).match?(input)
  end

  def test_iota_fold_class_alternation_preserves_virtual_tail
    source = "ᾷ"
    folded = source.downcase(:fold)
    [["(?i:[ᾀ])(?:ἀ|ι)", %w[ᾀἀι ᾀἀ ᾀι]],
     ["(?i:[#{source}])(?:α|ι)", [source + folded, source + folded[0], "#{source}ι"]]].each do |pattern, inputs|
      inputs.each do |input|
        assert_equal Regexp.new(pattern).match?(input), Onibi::Regexp.new(pattern).match?(input)
      end
    end
  end

  def test_dotted_i_fold_can_end_after_a_following_literal
    pattern = "(?i:İ)i\\z"
    input = "İi"

    assert_equal Regexp.new(pattern).match?(input), Onibi::Regexp.new(pattern).match?(input)
  end

  def test_non_iota_fold_prefix_can_end_at_an_absolute_anchor
    [["(?i:ŉ)ʼ\\z", "ŉʼ"], ["(?i:և)ե\\z", "ևե"],
     ["(?i:ẚ)a\\z", "ẚa"]].each do |pattern, input|
      assert_equal Regexp.new(pattern).match?(input), Onibi::Regexp.new(pattern).match?(input)
    end
  end

  def test_ignorecase_ascii_range_class_accepts_a_single_codepoint_fold
    pattern = "[a-z]+"
    input = "ſa"
    mri = Regexp.new(pattern, Regexp::IGNORECASE).match(input)
    onibi = Onibi::Regexp.new(pattern, Onibi::Regexp::IGNORECASE).match(input)

    assert_equal [mri[0], mri.offset(0)], [onibi[0], onibi.offset(0)]
  end

  def test_ignorecase_posix_class_keeps_full_fold_on_ascii_input
    pattern = "[[:upper:]]?a{1,2}É?"
    input = "ssa"
    mri = Regexp.new(pattern, Regexp::IGNORECASE).match(input)
    onibi = Onibi::Regexp.new(pattern, Onibi::Regexp::IGNORECASE).match(input)

    assert_equal [mri[0], mri.offset(0)], [onibi[0], onibi.offset(0)]
  end

  def test_ignorecase_capture_groups_preserve_fold_operand_boundaries
    pattern = "(ᾀ)(ἀι)"
    %w[ᾀἀι ᾀᾀἀι].each do |input|
      mri = Regexp.new(pattern, Regexp::IGNORECASE).match(input)
      onibi = Onibi::Regexp.new(pattern, Onibi::Regexp::IGNORECASE).match(input)

      assert_equal [mri&.[](0), mri&.offset(0)], [onibi&.[](0), onibi&.offset(0)]
    end
  end

  def test_ignorecase_full_fold_is_available_to_a_class_before_a_boundary
    pattern = "[[:alpha:]]\\b\\p{Letter}?"
    mri = Regexp.new(pattern, Regexp::IGNORECASE).match("SS")
    onibi = Onibi::Regexp.new(pattern, Regexp::IGNORECASE).match("SS")

    assert_equal ["SS", [0, 2]], [mri[0], mri.offset(0)]
    assert_equal [mri[0], mri.offset(0)], [onibi[0], onibi.offset(0)]
  end

  def test_property_fold_metadata_does_not_change_case_sensitive_classes
    pattern = "c*\\b{1,2}[ßé]?\\p{Ll}?"
    mri = Regexp.new(pattern).match("SS")
    onibi = Onibi::Regexp.new(pattern).match("SS")

    assert_equal ["", [0, 0]], [mri[0], mri.offset(0)]
    assert_equal [mri[0], mri.offset(0)], [onibi[0], onibi.offset(0)]
  end

  def test_casefold_candidate_cannot_extend_past_the_input_end
    pattern = "[ßé]\\b"
    mri = Regexp.new(pattern, Regexp::IGNORECASE).match("ß")
    onibi = Onibi::Regexp.new(pattern, Regexp::IGNORECASE).match("ß")

    assert_equal [mri[0], mri.offset(0)], [onibi[0], onibi.offset(0)]
  end

  def test_posix_class_uses_non_ascii_full_fold_before_a_boundary
    pattern = "[[:alpha:]]\\b"
    input = "i\u0307"
    mri = Regexp.new(pattern, Regexp::IGNORECASE).match(input)
    onibi = Onibi::Regexp.new(pattern, Regexp::IGNORECASE).match(input)

    assert_equal [input, [0, 2]], [mri[0], mri.offset(0)]
    assert_equal [mri[0], mri.offset(0)], [onibi[0], onibi.offset(0)]
  end

  def test_non_ascii_utf8_input_enables_posix_ascii_full_fold_in_the_vm
    pattern = "[[:alpha:]]\\b"
    input = "éSS"
    mri = Regexp.new(pattern, Regexp::IGNORECASE).match(input)
    onibi = Onibi::Regexp.new(pattern, Regexp::IGNORECASE).match(input)

    assert_equal ["SS", [1, 3]], [mri[0], mri.offset(0)]
    assert_equal [mri[0], mri.offset(0)], [onibi[0], onibi.offset(0)]
  end

  def test_posix_word_does_not_classify_emoji_as_a_word_character
    pattern = "[[:word:]]\\b"
    input = "😀SS"
    mri = Regexp.new(pattern, Regexp::IGNORECASE).match(input)
    onibi = Onibi::Regexp.new(pattern, Regexp::IGNORECASE).match(input)

    assert_equal ["SS", [1, 3]], [mri[0], mri.offset(0)]
    assert_equal [mri[0], mri.offset(0)], [onibi[0], onibi.offset(0)]
  end

  def test_casefolded_literal_run_can_cross_a_word_boundary
    pattern = "ss\\b"
    input = "😀ß"
    mri = Regexp.new(pattern, Regexp::IGNORECASE).match(input)
    onibi = Onibi::Regexp.new(pattern, Regexp::IGNORECASE).match(input)

    assert_equal ["ß", [1, 2]], [mri[0], mri.offset(0)]
    assert_equal [mri[0], mri.offset(0)], [onibi[0], onibi.offset(0)]
  end

  def test_casefold_can_cross_a_class_and_literal_operand
    pattern = "[s]s\\b"
    input = "😀ß"
    mri = Regexp.new(pattern, Regexp::IGNORECASE).match(input)
    onibi = Onibi::Regexp.new(pattern, Regexp::IGNORECASE).match(input)

    assert_equal ["ß", [1, 2]], [mri[0], mri.offset(0)]
    assert_equal [mri[0], mri.offset(0)], [onibi[0], onibi.offset(0)]
  end

  def test_property_operands_do_not_split_one_unicode_character
    pattern = "\\p{L}\\p{L}"
    input = "ß"
    mri = Regexp.new(pattern, Regexp::IGNORECASE).match(input)
    onibi = Onibi::Regexp.new(pattern, Regexp::IGNORECASE).match(input)

    assert_nil mri
    assert_nil onibi
  end

  def test_casefold_can_start_after_a_property_operand
    pattern = "\\p{L}[s]s"
    input = "sß"
    mri = Regexp.new(pattern, Regexp::IGNORECASE).match(input)
    onibi = Onibi::Regexp.new(pattern, Regexp::IGNORECASE).match(input)

    assert_equal ["sß", [0, 2]], [mri[0], mri.offset(0)]
    assert_equal [mri[0], mri.offset(0)], [onibi[0], onibi.offset(0)]
  end

  def test_casefold_range_keeps_the_greek_iota_compatibility_member
    pattern = "[ι]"
    expected = ::Regexp.new(pattern, ::Regexp::IGNORECASE).match("ι")
    actual = Onibi::Regexp.new(pattern, Onibi::Regexp::IGNORECASE).match("ι")

    assert_equal [expected&.to_a, expected&.offset(0)],
                 [actual&.to_a, actual&.offset(0)]
  end

  def test_adjacent_classes_do_not_split_one_unicode_character
    pattern = "[s][s]"
    input = "ß"
    mri = Regexp.new(pattern, Regexp::IGNORECASE).match(input)
    onibi = Onibi::Regexp.new(pattern, Regexp::IGNORECASE).match(input)

    assert_nil mri
    assert_nil onibi
  end

  def test_literal_casefold_direction_is_preserved
    pattern = "ßs"
    input = "sß"
    mri = Regexp.new(pattern, Regexp::IGNORECASE).match(input)
    onibi = Onibi::Regexp.new(pattern, Regexp::IGNORECASE).match(input)

    assert_equal ["sß", [0, 2]], [mri[0], mri.offset(0)]
    assert_equal [mri[0], mri.offset(0)], [onibi[0], onibi.offset(0)]
  end

  def test_negated_property_enables_full_casefold_for_following_posix_class
    pattern = "\\P{L}[[:alpha:]]\\b"
    input = "_SS"
    mri = Regexp.new(pattern, Regexp::IGNORECASE).match(input)
    onibi = Onibi::Regexp.new(pattern, Regexp::IGNORECASE).match(input)

    assert_equal ["_SS", [0, 3]], [mri[0], mri.offset(0)]
    assert_equal [mri[0], mri.offset(0)], [onibi[0], onibi.offset(0)]
  end

  def test_ascii8bit_non_ascii_bytes_do_not_match_unicode_posix_classes
    pattern = "[[:alpha:]]"
    input = "\xC3\xA9".b
    mri = Regexp.new(pattern).match(input)
    onibi = Onibi::Regexp.new(pattern).match(input)

    assert_nil mri
    assert_nil onibi
  end

  def test_ascii8bit_non_ascii_bytes_do_not_match_space_escape
    pattern = "\\s"
    input = "\xA0".b
    mri = Regexp.new(pattern).match(input)
    onibi = Onibi::Regexp.new(pattern).match(input)

    assert_nil mri
    assert_nil onibi
  end

  def test_windows31j_word_class_uses_the_decoded_character
    pattern = "[[:word:]]"
    input = "\xA9".b.force_encoding(Encoding::Windows_31J)
    mri = Regexp.new(pattern).match(input)
    onibi = Onibi::Regexp.new(pattern).match(input)

    assert_equal [input, [0, 1]], [mri[0], mri.offset(0)]
    assert_equal [mri[0], mri.offset(0)], [onibi[0], onibi.offset(0)]
  end

  def test_windows31j_word_property_uses_the_decoded_character
    pattern = "\\p{Word}".encode(Encoding::Windows_31J)
    input = "\xA1".b.force_encoding(Encoding::Windows_31J)
    mri = Regexp.new(pattern).match(input)
    onibi = Onibi::Regexp.new(pattern).match(input)

    assert_equal [input, [0, 1]], [mri[0], mri.offset(0)]
    assert_equal [mri[0], mri.offset(0)], [onibi[0], onibi.offset(0)]
  end

  def test_empty_pattern_keeps_empty_matches_under_ignorecase
    input = "éé"
    mri = input.scan(Regexp.new("", Regexp::IGNORECASE))
    onibi = Onibi::Regexp.new("", Regexp::IGNORECASE).scan(input)

    assert_equal ["", "", ""], mri
    assert_equal mri, onibi
  end

  def test_casefolded_literal_sequence_matches_composed_dotted_i
    pattern = "(i\\u0307)"
    input = "İ"
    mri = Regexp.new(pattern, Regexp::IGNORECASE).match(input)
    onibi = Onibi::Regexp.new(pattern, Regexp::IGNORECASE).match(input)

    assert_equal ["İ", [0, 1], %w[İ İ]], [mri[0], mri.offset(0), mri.to_a]
    assert_equal [mri[0], mri.offset(0), mri.to_a], [onibi[0], onibi.offset(0), onibi.to_a]
  end

  def test_literal_casefold_sequences_cover_modifier_letter_expansions
    { "ʼn" => "ŉ", "aʾ" => "ẚ" }.each do |pattern, input|
      mri = Regexp.new(pattern, Regexp::IGNORECASE).match(input)
      onibi = Onibi::Regexp.new(pattern, Regexp::IGNORECASE).match(input)

      assert_equal [input, [0, 1]], [mri[0], mri.offset(0)]
      assert_equal [mri[0], mri.offset(0)], [onibi[0], onibi.offset(0)]
    end
  end

  def test_class_casefold_split_is_limited_to_sharp_s
    { "[ß]s" => "sß", "[ﬆ]s" => "sﬆ" }.each do |pattern, input|
      mri = Regexp.new(pattern, Regexp::IGNORECASE).match(input)
      onibi = Onibi::Regexp.new(pattern, Regexp::IGNORECASE).match(input)

      assert_equal mri && [mri[0], mri.offset(0)], onibi && [onibi[0], onibi.offset(0)]
    end
  end

  def test_expanded_fold_with_combining_marks_keeps_following_class_operand
    pattern = "ΐ[a-z]"
    input = "ΐa"
    mri = Regexp.new(pattern, Regexp::IGNORECASE).match(input)
    onibi = Onibi::Regexp.new(pattern, Onibi::Regexp::IGNORECASE).match(input)

    assert_equal [mri&.[](0), mri&.offset(0)], [onibi&.[](0), onibi&.offset(0)]
  end

  def test_expanded_fold_literal_can_be_followed_by_a_class_operand
    pattern = "ᾀ[a-z]"
    input = "ᾀa"
    mri = Regexp.new(pattern, Regexp::IGNORECASE).match(input)
    onibi = Onibi::Regexp.new(pattern, Onibi::Regexp::IGNORECASE).match(input)

    assert_equal [mri&.[](0), mri&.offset(0)], [onibi&.[](0), onibi&.offset(0)]
  end

  def test_nested_capture_preserves_expanded_fold_boundary
    pattern = "(?<x>(ᾀ))a"
    input = "ᾀa"
    mri = Regexp.new(pattern, Regexp::IGNORECASE).match(input)
    onibi = Onibi::Regexp.new(pattern, Onibi::Regexp::IGNORECASE).match(input)

    assert_nil mri
    assert_nil onibi
  end

  def test_iota_fold_does_not_match_when_followed_by_an_incompatible_literal
    pattern = "(?i:ᾀ)α"
    input = "ᾀα"
    mri = Regexp.new(pattern).match(input)
    onibi = Onibi::Regexp.new(pattern).match(input)

    assert_nil mri
    assert_nil onibi
  end

  def test_iota_fold_alternation_can_match_after_an_extra_character
    pattern = "(?i:[ᾀ])(?:ἀ|x)"
    input = "ᾀἀἀ"
    mri = Regexp.new(pattern).match(input)
    onibi = Onibi::Regexp.new(pattern).match(input)

    assert_equal [mri&.[](0), mri&.offset(0)], [onibi&.[](0), onibi&.offset(0)]
  end

  def test_iota_fold_positive_lookahead_can_match_after_an_extra_character
    pattern = "(?i:ᾁ)(?=ἀ)"
    input = "ᾁἀἀ"
    mri = Regexp.new(pattern).match(input)
    onibi = Onibi::Regexp.new(pattern).match(input)

    assert_equal [mri&.[](0), mri&.offset(0)], [onibi&.[](0), onibi&.offset(0)]
  end

  def test_iota_fold_source_does_not_match_at_a_strict_end_anchor
    pattern = "(?i:ᾀ)\\z"
    input = "ᾀ"
    mri = Regexp.new(pattern).match(input)
    onibi = Onibi::Regexp.new(pattern).match(input)

    assert_nil mri
    assert_nil onibi
  end

  def test_alternation_keeps_expanded_fold_branch_order
    pattern = "(?<x>ᾀ)a|é"
    input = "ᾀa"
    mri = Regexp.new(pattern, Regexp::IGNORECASE).match(input)
    onibi = Onibi::Regexp.new(pattern, Onibi::Regexp::IGNORECASE).match(input)

    assert_equal [mri&.to_a, mri&.offset(0)], [onibi&.to_a, onibi&.offset(0)]
  end

  def test_captured_iota_fold_keeps_boundary_for_following_alternation
    pattern = "(?i:(ᾀ))(?:ἀ|x)"
    input = "ᾀἀι"
    mri = Regexp.new(pattern).match(input)
    onibi = Onibi::Regexp.new(pattern).match(input)

    assert_equal [mri&.[](0), mri&.offset(0)], [onibi&.[](0), onibi&.offset(0)]
  end

  def test_captured_iota_fold_rejects_an_incompatible_alternation_branch
    pattern = "(?i:(ᾀ))(?:ἀ|x)"
    input = "ᾀx"
    mri = Regexp.new(pattern, Regexp::IGNORECASE).match(input)
    onibi = Onibi::Regexp.new(pattern, Onibi::Regexp::IGNORECASE).match(input)

    assert_nil mri
    assert_nil onibi
  end

  def test_captured_iota_fold_does_not_split_before_a_literal_tail
    pattern = "(?i:(ᾀ))x"
    input = "ᾀx"
    mri = Regexp.new(pattern).match(input)
    onibi = Onibi::Regexp.new(pattern).match(input)
    assert_equal [mri&.[](0), mri&.offset(0)], [onibi&.[](0), onibi&.offset(0)]
  end

  def test_iota_fold_class_does_not_split_before_a_literal_tail
    pattern = "(?i:[ᾀ])x"
    input = "ᾈx"
    mri = Regexp.new(pattern).match(input)
    onibi = Onibi::Regexp.new(pattern).match(input)
    assert_equal [mri&.[](0), mri&.offset(0)], [onibi&.[](0), onibi&.offset(0)]
  end

  def test_iota_fold_alternation_can_use_a_source_character_branch
    pattern = "(?i:ᾀ)(?:x|ᾀ)"
    input = "ᾀᾀx"
    mri = Regexp.new(pattern).match(input)
    onibi = Onibi::Regexp.new(pattern).match(input)
    assert_equal [mri&.[](0), mri&.offset(0)], [onibi&.[](0), onibi&.offset(0)]
  end

  def test_iota_fold_quantifier_does_not_split_before_a_literal_tail
    pattern = "(?i:ᾀ){1,2}x"
    input = "ᾀx"
    mri = Regexp.new(pattern).match(input)
    onibi = Onibi::Regexp.new(pattern).match(input)
    assert_equal [mri&.[](0), mri&.offset(0)], [onibi&.[](0), onibi&.offset(0)]
  end

  def test_iota_fold_class_alternation_can_use_a_source_character_branch
    pattern = "(?i:[ᾀ])(?:x|ᾀ)"
    input = "ᾀᾀx"
    mri = Regexp.new(pattern).match(input)
    onibi = Onibi::Regexp.new(pattern).match(input)
    assert_equal [mri&.[](0), mri&.offset(0)], [onibi&.[](0), onibi&.offset(0)]
  end

  def test_reverse_simple_fold_source_does_not_split_before_a_literal_tail
    [["(?i:K)x", "Kx"], ["(?i:k)x", "Kx"], ["(?i:[K])x", "Kx"]].each do |pattern, input|
      mri = Regexp.new(pattern).match(input)
      onibi = Onibi::Regexp.new(pattern).match(input)
      assert_equal [mri&.[](0), mri&.offset(0)], [onibi&.[](0), onibi&.offset(0)]
    end
  end

  def test_reverse_fold_optional_sources_follow_mri_operand_boundaries
    [
      ["(?i:ϖ)?x", "ϖx"],
      ["(?i:ι)?x", "ͅx"],
      ["(?i:ͅ)?x", "ͅx"],
      ["(?i:ᾀ)?x", "ᾀx"],
      ["(?i:ᾀ|x)y", "ᾀy"]
    ].each do |pattern, input|
      mri = Regexp.new(pattern).match(input)
      onibi = Onibi::Regexp.new(pattern).match(input)
      assert_equal [mri&.[](0), mri&.offset(0)], [onibi&.[](0), onibi&.offset(0)]
    end
  end

  def test_reverse_fold_alternation_keeps_branch_source_policy
    [
      ["(?i:k|ß)x", "Kx"],
      ["(?i:s|ἀ)x", "ſx"],
      ["(?i:k|ι)x", "Kx"],
      ["(?i:ᾀ|ᾀ)x", "ᾀx"],
      ["(?i:(ᾀ))\\1\\z", "ᾀᾀ"]
    ].each do |pattern, input|
      mri = Regexp.new(pattern).match(input)
      onibi = Onibi::Regexp.new(pattern).match(input)
      assert_equal [mri&.[](0), mri&.offset(0)], [onibi&.[](0), onibi&.offset(0)]
    end
  end

  def test_reverse_fold_class_and_capture_boundaries_match_mri
    [
      ["(?i:[s])s", "ſs"],
      ["(?i:[ſ])s", "ſs"],
      ["(?i:([ß]))\\1\\z", "ßß"],
      ["(?i:(ᾀ))\\1\\z", "ᾀᾀ"]
    ].each do |pattern, input|
      mri = Regexp.new(pattern).match(input)
      onibi = Onibi::Regexp.new(pattern).match(input)
      assert_equal [mri&.[](0), mri&.offset(0)], [onibi&.[](0), onibi&.offset(0)]
    end
  end

  def test_unicode_property_classes_keep_following_operand_matches
    [
      ["(?i:[\\p{L}])x", "ſx"],
      ["(?i:[\\p{Greek}])x", "ᾀx"],
      ["(?i:[\\p{Greek}])ι", "ᾀι"]
    ].each do |pattern, input|
      mri = Regexp.new(pattern).match(input)
      onibi = Onibi::Regexp.new(pattern).match(input)
      assert_equal [mri&.[](0), mri&.offset(0)], [onibi&.[](0), onibi&.offset(0)]
    end
  end

  def test_simple_fold_boundaries_across_assertions_option_groups_and_alternations
    [
      ["(?i:(?=s)s)x", "ſx"],
      ["(?i:s?)x", "ſx"],
      ["(?i:^s)ſ", "ſſx"],
      ["(?i:(?<=s)x)", "ſx"],
      ["(?i:(ſ|s))x", "ſx"],
      ["(?i:(s|k))x", "ſx"],
      ["(?i:ſ)\\z", "ſ"],
      ["(?i:K)\\z", "K"],
      ["(?i:(?:ᾀ|ᾀ))x", "ᾀx"],
      ["(?i:s)(?=x)", "ſx"],
      ["(?i:s?)(?=x)", "ſx"],
      ["(?i:(?:s|s))s", "ſs"],
      ["(?i:(?:s|s))\\z", "ſ"],
      ["(?i:(?:s|s))(?=x)", "ſx"],
      ["(?i:(?:s|s)s)x", "ſſx"],
      ["(?i:(?:s|ſ)s)x", "ſſx"],
      ["(?i:k?)\\z", "K"],
      ["(?i:ι)\\z", "ᾀι"],
      ["(?i:[ι]?)x", "ͅx"],
      ["(?i:kk)\\z", "Kk"],
      ["(?i:kK)\\z", "Kk"],
      ["(?i:kk)x", "KKx"],
      ["(?i:k?k)x", "Kx"],
      ["(?i:k?K)x", "Kx"]
    ].each do |pattern, input|
      mri = Regexp.new(pattern).match(input)
      onibi = Onibi::Regexp.new(pattern).match(input)
      assert_equal [mri&.[](0), mri&.offset(0)], [onibi&.[](0), onibi&.offset(0)]
    end
  end

  def test_longest_reverse_fold_prefix_is_selected
    pattern = "\\bὒa"
    input = "ὒa"
    mri = Regexp.new(pattern, Regexp::IGNORECASE).match(input)
    onibi = Onibi::Regexp.new(pattern, Regexp::IGNORECASE).match(input)

    assert_equal ["ὒa", [0, 2]], [mri[0], mri.offset(0)]
    assert_equal [mri[0], mri.offset(0)], [onibi[0], onibi.offset(0)]
  end

  private

  def assert_same_outcome(pattern, input, expected, options = 0)
    mri = outcome(Regexp, pattern, input, options)
    onibi = outcome(Onibi::Regexp, pattern, input, options)

    assert_equal expected, mri, "MRI outcome for #{pattern.inspect} / #{input.inspect}"
    assert_equal mri, onibi, "Onibi outcome for #{pattern.inspect} / #{input.inspect}"
  end

  def outcome(regexp_class, pattern, input, options = 0)
    regexp_class.new(pattern, options).match?(input) || false
  rescue StandardError
    :error
  end
end
