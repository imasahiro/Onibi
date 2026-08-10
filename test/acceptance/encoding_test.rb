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
end
