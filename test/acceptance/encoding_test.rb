# frozen_string_literal: true

require "test_helper"

class EncodingTest < Minitest::Test
  def test_utf8_literals_and_classes_match
    assert Onibi::Regexp.new("é").match?("café")
    assert Onibi::Regexp.new("[é]").match?("é")
    assert Onibi::Regexp.new("(é)+").match?("éé")
  end

  def test_ascii8bit_literals_and_classes_match
    pattern = "[a-c]".b
    input = "zzb".b

    assert Onibi::Regexp.new(pattern).match?(input)
    assert Onibi::Regexp.new("\\d".b).match?("7".b)
  end

  def test_valid_utf8_input_matches_normally
    valid_utf8 = "é".encode(Encoding::UTF_8)

    assert Onibi::Regexp.new(".".encode(Encoding::UTF_8)).match?(valid_utf8)
  end

  def test_invalid_utf8_input_raises_argument_error
    invalid_utf8 = [0xff].pack("C*").force_encoding(Encoding::UTF_8)

    assert_raises(ArgumentError) do
      Onibi::Regexp.new(".".encode(Encoding::UTF_8)).match?(invalid_utf8)
    end
  end

  def test_invalid_utf8_pattern_raises_regexp_error
    invalid_utf8 = [0xff].pack("C*").force_encoding(Encoding::UTF_8)

    assert_raises(Onibi::RegexpError) { Onibi::Regexp.new(invalid_utf8) }
  end

  def test_incompatible_pattern_and_input_encodings_raise
    utf8_pattern = "é".encode(Encoding::UTF_8)
    ascii8bit_input = "é".b

    assert_raises(Encoding::CompatibilityError) do
      Onibi::Regexp.new(utf8_pattern).match?(ascii8bit_input)
    end
  end

  def test_non_ascii_pattern_accepts_ascii_only_input_in_another_encoding
    pattern = "é".encode(Encoding::UTF_8)
    input = "a".encode(Encoding::EUC_JP)

    refute Onibi::Regexp.new(pattern).match?(input)
  end

  def test_noencoding_matches_binary_input_one_byte_at_a_time
    regexp = Onibi::Regexp.new(".", Onibi::Regexp::NOENCODING)

    assert_equal Onibi::Regexp::NOENCODING, regexp.options
    assert regexp.match?("é".b)
  end

  def test_noencoding_rejects_non_ascii_patterns
    assert_raises(Onibi::RegexpError) do
      Onibi::Regexp.new("é", Onibi::Regexp::NOENCODING)
    end
  end

  def test_encoding_flags_are_reflected_by_encoding_introspection
    fixed = Onibi::Regexp.new("a", Onibi::Regexp::FIXEDENCODING)
    noencoding = Onibi::Regexp.new("a", Onibi::Regexp::NOENCODING)

    assert_equal Encoding::UTF_8, fixed.encoding
    assert fixed.fixed_encoding?
    assert_equal Encoding::US_ASCII, noencoding.encoding
    refute noencoding.fixed_encoding?
  end

  def test_non_ascii_patterns_report_implicit_fixed_encoding
    regexp = Onibi::Regexp.new("あ")

    assert_equal Onibi::Regexp::FIXEDENCODING, regexp.options
    assert_equal Encoding::UTF_8, regexp.encoding
    assert regexp.fixed_encoding?
  end

  def test_unicode_property_patterns_report_their_source_encoding
    pattern = "\\p{Hiragana}".encode(Encoding::EUC_JP)
    regexp = Onibi::Regexp.new(pattern)

    assert_equal Onibi::Regexp::FIXEDENCODING, regexp.options
    assert_equal Encoding::EUC_JP, regexp.encoding
    assert regexp.fixed_encoding?
  end

  def test_fixed_encoding_rejects_non_ascii_input_in_another_encoding
    regexp = Onibi::Regexp.new("a", Onibi::Regexp::FIXEDENCODING)

    assert_raises(Encoding::CompatibilityError) do
      regexp.match?("あ".encode(Encoding::EUC_JP))
    end
  end

  def test_unicode_properties_decode_non_utf8_inputs
    [Encoding::EUC_JP, Encoding::Windows_31J].each do |encoding|
      pattern = "\\p{Hiragana}".encode(encoding)
      input = "あ".encode(encoding)

      assert Onibi::Regexp.new(pattern).match?(input)
    end
  end

  def test_ascii_patterns_are_compatible_with_non_ascii_inputs
    [Encoding::EUC_JP, Encoding::Windows_31J].each do |encoding|
      refute Onibi::Regexp.new("a").match?("あ".encode(encoding))
    end
  end

  def test_ascii_character_classes_reject_non_ascii_input_without_error
    [Encoding::EUC_JP, Encoding::Windows_31J, Encoding::ASCII_8BIT].each do |pattern_encoding|
      pattern = "[a-z]".encode(pattern_encoding)
      input = "あ".encode(Encoding::UTF_8)

      refute Onibi::Regexp.new(pattern).match?(input)
    end
  end

  def test_noencoding_accepts_binary_byte_patterns
    byte = [0xa4].pack("C").b
    regexp = Onibi::Regexp.new(byte, Onibi::Regexp::NOENCODING)

    assert regexp.match?(byte)
  end

  def test_match_decodes_non_utf8_unicode_properties
    [Encoding::EUC_JP, Encoding::Windows_31J].each do |encoding|
      regexp = Onibi::Regexp.new("\\p{Hiragana}".encode(encoding))

      refute_nil regexp.match("あ".encode(encoding))
    end
  end

  def test_ascii8bit_patterns_reject_unicode_properties
    assert_raises(Onibi::RegexpError) do
      Onibi::Regexp.new("\\p{Hiragana}".b)
    end
  end

  def test_noencoding_patterns_reject_unicode_properties
    assert_raises(Onibi::RegexpError) do
      Onibi::Regexp.new("\\p{Hiragana}", Onibi::Regexp::NOENCODING)
    end
  end
end
