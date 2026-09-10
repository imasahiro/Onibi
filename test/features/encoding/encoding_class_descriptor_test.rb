# frozen_string_literal: true

require "test_helper"

class EncodingClassDescriptorTest < Minitest::Test
  def test_rseq_publishes_each_class_descriptor_family
    cases = {
      "[a-z]" => [:ascii_bitmap],
      "[あ-い]" => [:codepoint_ranges],
      "\\p{Lower}" => [:encoding_ctype],
      "[\\p{Alpha}&&[^A-Z]]" => [:mixed]
    }

    cases.each do |pattern, kinds|
      info = Onibi::Regexp.new(pattern).send(:__onibi_diagnostics__, "é")

      assert info[:rseq], pattern
      assert_equal kinds, info[:class_kinds], pattern
    end
  end

  def test_properties_and_intersections_execute_without_fallback
    cases = [
      ["\\p{Lower}", "é"],
      ["\\p{Alpha}", "あ"],
      ["\\p{Word}", "あ"],
      ["[[:word:]]", "あ"],
      ["[^[:digit:]]", "é"],
      ["[\\p{Alpha}&&[^A-Z]]", "é"]
    ]

    cases.each do |pattern, input|
      regexp = Onibi::Regexp.new(pattern)
      info = regexp.send(:__onibi_diagnostics__, input)

      assert_equal Regexp.new(pattern).match?(input), regexp.match?(input), pattern
      assert_equal 1, info[:status], pattern
      assert_equal 0, info[:fallback], pattern
    end
  end

  def test_non_utf8_classes_and_word_boundaries_use_encoded_characters
    [Encoding::EUC_JP, Encoding::Windows_31J].each do |encoding|
      ["\\p{Hiragana}", "[[:word:]]", "\\bあ\\b"].each do |source|
        pattern = source.encode(encoding)
        input = "あ".encode(encoding)
        regexp = Onibi::Regexp.new(pattern)
        info = regexp.send(:__onibi_diagnostics__, input)

        assert_equal Regexp.new(pattern).match?(input), regexp.match?(input),
                     "#{encoding.name}: #{source}"
        assert_equal 1, info[:status], "#{encoding.name}: #{source}"
        assert_equal 0, info[:fallback], "#{encoding.name}: #{source}"
      end
    end
  end

  def test_class_semantics_across_the_encoding_matrix
    cases = {
      Encoding::UTF_8 => %w[é あ],
      Encoding::EUC_JP => %w[a あ],
      Encoding::Windows_31J => %w[a あ],
      Encoding::ASCII_8BIT => %w[a _],
      Encoding::ISO_8859_1 => %w[é é]
    }

    cases.each do |encoding, (lower, word)|
      checks = [
        ["\\p{Lower}", lower],
        ["\\p{Alpha}", word],
        ["\\p{Word}", word],
        ["[[:word:]]", word],
        ["[^[:digit:]]", word],
        ["[[:alpha:]&&[^A-Z]]", lower]
      ]

      checks.each do |source, input|
        pattern = source.encode(encoding)
        subject = input.encode(encoding)
        regexp = Onibi::Regexp.new(pattern)
        info = regexp.send(:__onibi_diagnostics__, subject)
        message = "#{encoding.name}: #{source}"
        expected = Regexp.new(pattern).match?(subject)

        assert_equal expected, regexp.match?(subject), message
        assert_equal expected ? 1 : 0, info[:status], message
        assert_equal 0, info[:fallback], message
      end
    end
  end

  def test_word_boundaries_use_encoded_characters_across_the_encoding_matrix
    cases = {
      Encoding::UTF_8 => "é",
      Encoding::EUC_JP => "あ",
      Encoding::Windows_31J => "あ",
      Encoding::ASCII_8BIT => "a",
      Encoding::ISO_8859_1 => "é"
    }

    cases.each do |encoding, character|
      pattern = "\\b#{character}\\b".encode(encoding)
      subject = character.encode(encoding)
      regexp = Onibi::Regexp.new(pattern)
      info = regexp.send(:__onibi_diagnostics__, subject)

      assert_equal Regexp.new(pattern).match?(subject), regexp.match?(subject), encoding.name
      assert_equal 1, info[:status], encoding.name
      assert_equal 0, info[:fallback], encoding.name
    end
  end

  def test_ignorecase_closure_is_not_a_runtime_descriptor_flag
    plain = Onibi::Regexp.new("[a-z]", Regexp::IGNORECASE)
    negated = Onibi::Regexp.new("[^a-z]", Regexp::IGNORECASE)

    assert_equal [0], plain.send(:__onibi_diagnostics__, "S")[:class_flags]
    assert_equal [1], negated.send(:__onibi_diagnostics__, "S")[:class_flags]
  end

  def test_ignorecase_classes_match_mri_across_the_encoding_matrix
    cases = {
      Encoding::UTF_8 => ["[a-z]", "ſ"],
      Encoding::EUC_JP => ["[a-z]", "S"],
      Encoding::Windows_31J => ["[a-z]", "S"],
      Encoding::ASCII_8BIT => ["[a-z]", "S"],
      Encoding::ISO_8859_1 => ["[a-z]", "S"]
    }

    cases.each do |encoding, (source, input)|
      pattern = source.encode(encoding)
      subject = input.encode(encoding)
      expected = Regexp.new(pattern, Regexp::IGNORECASE).match?(subject)
      regexp = Onibi::Regexp.new(pattern, Regexp::IGNORECASE)
      info = regexp.send(:__onibi_diagnostics__, subject)
      actual = regexp.match?(subject)

      assert_equal expected, actual, encoding.name
      assert_equal 1, info[:status], encoding.name
      assert_equal 0, info[:fallback], encoding.name
    end
  end

  def test_inline_ignorecase_class_executes_without_fallback
    cases = [["(?i:[a-z])", "ſ"], ["(?i:[^a-z])", "!"]]

    cases.each do |pattern, subject|
      regexp = Onibi::Regexp.new(pattern)
      info = regexp.send(:__onibi_diagnostics__, subject)

      assert_equal Regexp.new(pattern).match?(subject), regexp.match?(subject), pattern
      assert_equal 1, info[:status], pattern
      assert_equal 0, info[:fallback], pattern
    end
  end

  def test_global_ignorecase_class_executes_without_fallback
    regexp = Onibi::Regexp.new("[a-z]", Regexp::IGNORECASE)

    %w[S ſ].each do |subject|
      info = regexp.send(:__onibi_diagnostics__, subject)

      assert regexp.match?(subject), subject
      assert_equal 1, info[:status], subject
      assert_equal 0, info[:fallback], subject
    end
  end

  def test_incomplete_fold_paths_keep_the_exact_fallback_gate
    cases = [
      ["ss\\b", "😀ß", 0],
      ["[s]s\\b", "😀ß", 1],
      ["[ß]", "SS", 1],
      ["[s]{2}", "ß", 1]
    ]

    cases.each do |pattern, subject, class_count|
      regexp = Onibi::Regexp.new(pattern, Regexp::IGNORECASE)
      info = regexp.send(:__onibi_diagnostics__, subject)
      expected = Regexp.new(pattern, Regexp::IGNORECASE).match(subject)
      actual = regexp.match(subject)

      assert_equal [expected&.[](0), expected&.offset(0)], [actual&.[](0), actual&.offset(0)]
      assert_equal 2, info[:status], pattern
      assert_equal class_count, info[:class_kinds].length, pattern
    end
  end

  def test_repeated_class_without_a_multi_character_fold_executes
    regexp = Onibi::Regexp.new("[q]{2}", Regexp::IGNORECASE)
    info = regexp.send(:__onibi_diagnostics__, "QQ")

    assert regexp.match?("QQ")
    assert_equal 1, info[:status]
    assert_equal 0, info[:fallback]
  end
end
