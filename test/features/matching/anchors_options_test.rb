# frozen_string_literal: true

require "test_helper"

class AnchorsOptionsTest < Minitest::Test
  def test_anchors_match_whole_input
    assert Onibi::Regexp.new("^cat$").match?("cat")
    refute Onibi::Regexp.new("^cat$").match?("wildcat")
  end

  def test_case_insensitive_option
    assert Onibi::Regexp.new("cat", ["ignorecase"]).match?("A CAT")
  end

  def test_multiline_option
    assert Onibi::Regexp.new("^cat$", ["multiline"]).match?("dog\ncat\nbird")
  end

  def test_line_start_does_not_match_the_empty_line_after_a_final_newline
    pattern = "^\\z"
    input = "a\n"

    assert_nil ::Regexp.new(pattern).match(input)
    assert_nil Onibi::Regexp.new(pattern).match(input)
  end

  def test_line_start_boundaries_follow_mri_at_character_and_input_edges
    cases = [
      ["^", "", 0], ["^\\z", "", 0],
      ["^", "a", 0], ["^\\z", "a", 0],
      ["^", "a\nb", 0], ["^", "a\nb", 1], ["^", "a\nb", 2],
      ["^", "a\nb", 3], ["^\\z", "a\nb", 0],
      ["^", "a\n", 0], ["^", "a\n", 2],
      ["^\\z", "a\n", 0], ["^\\z", "a\n", 2]
    ]

    cases.each do |pattern, input, offset|
      mri = ::Regexp.new(pattern).match(input, offset)
      regexp = Onibi::Regexp.new(pattern)
      actual = regexp.match(input, offset)
      info = regexp.send(:__onibi_diagnostics__, input)
      message = "#{pattern.inspect} #{input.inspect} offset #{offset}"

      assert_match_snapshot mri, actual, message
      assert_equal true, info[:rseq], message
      assert_equal 0, info[:fallback], message
      assert_operator info.values_at(:regular, :tagged, :dynamic).sum, :>, 0, message
    end
  end

  def test_line_start_uses_encoded_character_boundaries_with_native_classes
    false_start_subjects = {
      Encoding::UTF_16LE => "\u0A41Z",
      Encoding::UTF_16BE => "\u410AZ",
      Encoding::UTF_32LE => "\u0A41Z",
      Encoding::UTF_32BE => "\u010AZ"
    }

    false_start_subjects.each do |encoding, text|
      cases = [
        ["[\\p{Any}]^[\\p{Any}]", text],
        ["[\\p{Any}]\\n^[\\p{Any}]", "a\nb"]
      ]

      cases.each do |source, input_text|
        pattern = source.encode(encoding)
        input = input_text.encode(encoding)
        mri = ::Regexp.new(pattern).match(input)
        regexp = Onibi::Regexp.new(pattern)
        actual = regexp.match(input)
        info = regexp.send(:__onibi_diagnostics__, input)
        message = "#{encoding.name}: #{source}"

        assert_match_snapshot mri, actual, message
        assert_equal true, info[:rseq], message
        assert_includes info[:class_kinds], :encoding_ctype, message
        assert_equal 0, info[:fallback], message
        assert_operator info.values_at(:regular, :tagged, :dynamic).sum, :>, 0, message
      end
    end
  end

  def test_end_assertions_match_mri_at_ascii_boundaries_and_offsets
    anchors = ["$", "\\Z", "\\z"]
    inputs = ["", "abc", "a\nb", "a\n", "a\n\n"]
    cases = anchors.product(inputs).map { |anchor, input| [anchor, input, 0] }
    cases.concat(anchors.product([1, 2, 3]).map { |anchor, offset| [anchor, "a\nb", offset] })

    cases.each do |anchor, input, offset|
      source = "[\\p{Any}]?#{anchor}"
      mri = ::Regexp.new(source).match(input, offset)
      regexp = Onibi::Regexp.new(source)
      actual = regexp.match(input, offset)
      info = regexp.send(:__onibi_diagnostics__, input)
      message = "#{source.inspect} #{input.inspect} offset #{offset}"

      assert_match_snapshot mri, actual, message
      assert_equal true, info[:rseq], message
      assert_equal 0, info[:fallback], message
      assert_operator info.values_at(:regular, :tagged, :dynamic).sum, :>, 0, message
    end
  end

  def test_end_assertions_use_encoded_character_boundaries_with_native_classes
    encodings = [
      Encoding::ASCII_8BIT,
      Encoding::UTF_8,
      Encoding::UTF_16LE,
      Encoding::UTF_16BE,
      Encoding::UTF_32LE,
      Encoding::UTF_32BE
    ]
    non_lf_subjects = {
      Encoding::ASCII_8BIT => "A".b,
      Encoding::UTF_8 => "\u010A",
      Encoding::UTF_16LE => "\u410A",
      Encoding::UTF_16BE => "\u0A41",
      Encoding::UTF_32LE => "\u010A",
      Encoding::UTF_32BE => "\u010A"
    }
    cases = [
      ["$", "a\nb", true],
      ["\\Z", "a\n", false],
      ["\\n\\Z", "a\n\n", false]
    ]

    encodings.each do |encoding|
      class_source = encoding == Encoding::ASCII_8BIT ? "[\\x00-\\xFF]" : "[\\p{Any}]"
      cases.each do |suffix, text, trailing_class|
        source = "#{class_source}#{suffix}#{trailing_class ? class_source : ""}"
        pattern = source.encode(encoding)
        input = text.encode(encoding)
        mri = ::Regexp.new(pattern).match(input)
        regexp = Onibi::Regexp.new(pattern)
        actual = regexp.match(input)
        info = regexp.send(:__onibi_diagnostics__, input)
        message = "#{encoding.name}: #{source}"

        assert_match_snapshot mri, actual, message
        assert_equal true, info[:rseq], message
        assert_equal 0, info[:fallback], message
        assert_operator info.values_at(:regular, :tagged, :dynamic).sum, :>, 0, message
        refute_empty info[:class_kinds], message
        assert_includes info[:class_kinds], :encoding_ctype, message unless encoding == Encoding::ASCII_8BIT
      end

      source = "$#{class_source}".encode(encoding)
      input = non_lf_subjects.fetch(encoding).encode(encoding)
      mri = ::Regexp.new(source).match(input)
      regexp = Onibi::Regexp.new(source)
      actual = regexp.match(input)
      info = regexp.send(:__onibi_diagnostics__, input)
      message = "#{encoding.name}: non-LF character after $"

      assert_match_snapshot mri, actual, message
      assert_equal true, info[:rseq], message
      assert_equal 0, info[:fallback], message
      assert_operator info.values_at(:regular, :tagged, :dynamic).sum, :>, 0, message
      refute_empty info[:class_kinds], message
      assert_includes info[:class_kinds], :encoding_ctype, message unless encoding == Encoding::ASCII_8BIT
    end
  end

  private

  def match_snapshot(match)
    return nil unless match

    [match.to_a, match.offset(0), match.byteoffset(0)]
  end

  def assert_match_snapshot(expected, actual, message)
    return assert_nil(actual, message) unless expected

    assert_equal match_snapshot(expected), match_snapshot(actual), message
  end
end
