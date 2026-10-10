# frozen_string_literal: true

require "test_helper"

class MatchDataCharacterOffsetsTest < Minitest::Test
  def payload(subject, ranges, source = "(a)")
    Onibi::MatchData.send(:__onibi_new__, Onibi::Regexp.new(source), subject,
                          ranges)
  end

  def result(callable)
    [:value, callable.call]
  rescue StandardError => e
    [:error, e.class, e.message]
  end

  def assert_differential(mri, onibi, method, *arguments)
    assert_equal result(-> { mri.public_send(method, *arguments) }),
                 result(-> { onibi.public_send(method, *arguments) })
  end

  def test_multibyte_character_offsets_and_match_length_match_mri
    subject = "xxé界yy"
    mri = ::Regexp.new("(é界)(?<empty>)?(?<missing>a)?").match(subject)
    ranges = mri.length.times.map do |index|
      begin_offset, end_offset = mri.offset(index)
      if begin_offset
        [subject[0, begin_offset].bytesize, subject[0, end_offset].bytesize]
      else
        [-1, -1]
      end
    end
    onibi = payload(subject, ranges, "(é界)(?<empty>)?(?<missing>a)?")

    mri.length.times do |index|
      %i[begin end offset match_length].each do |method|
        assert_differential(mri, onibi, method, index)
      end
    end
    assert_equal [2, 4], onibi.offset(0)
    assert_equal 2, onibi.match_length(0)
    assert_equal [4, 4], onibi.offset(:empty)
    assert_equal [nil, nil], onibi.offset(:missing)
  end

  def test_duplicate_names_and_selectors_use_mri_coercion
    subject = "é"
    source = "(?<word>é)(?<word>a)?"
    mri = ::Regexp.new(source).match(subject)
    onibi = payload(subject, [[0, 2], [0, 2], [-1, -1]], source)

    [0, 0.9, -0.1, :word, "word"].each do |selector|
      %i[begin end offset match_length].each do |method|
        assert_differential(mri, onibi, method, selector)
      end
    end
    [nil, Float::NAN, Float::INFINITY, 99].each do |selector|
      %i[begin end offset match_length].each do |method|
        assert_differential(mri, onibi, method, selector)
      end
    end
  end

  def test_cache_is_absent_until_character_access_and_is_reused
    match_data = payload("é", [[0, 2], [0, 2]], "(é)")
    summary = -> { match_data.send(:__onibi_match_data_diagnostics__) }

    refute summary.call[:character_cache_present]
    first = match_data.offset(0)
    assert summary.call[:character_cache_present]
    second = match_data.offset(0)
    refute_same first, second
    assert_equal [0, 1], first
    assert_equal [0, 1], second
    first[0] = 99
    assert_equal [0, 1], match_data.offset(0)
  end

  def test_unmatched_and_empty_ranges_do_not_publish_partial_values
    match_data = payload("é", [[0, 2], [0, 0], [-1, -1]],
                         "(é)(?<empty>)(?<missing>a)?")

    assert_nil match_data.begin(:missing)
    assert_equal [nil, nil], match_data.offset(:missing)
    assert_nil match_data.match_length(:missing)
    assert_equal [0, 0], match_data.offset(:empty)
    assert_equal 0, match_data.match_length(:empty)
  end

  def test_binary_combining_and_non_utf8_subjects_count_codepoints
    binary = payload("\xffa".b, [[1, 2], [1, 2]], "(a)")
    assert_equal [1, 2], binary.offset(0)
    assert_equal 1, binary.match_length(0)

    combining = "e\u0301"
    assert_equal [0, 2], payload(combining, [[0, 2], [0, 2]], "(.)").offset(0)

    windows_31j = "あa".encode("Windows-31J")
    assert_equal [0, 1],
                 payload(windows_31j, [[0, 2], [0, 2]], "(x)").offset(0)
  end

  def test_invalid_utf8_raises_without_publishing_cache
    invalid = String.new("\xffa", encoding: Encoding::UTF_8)
    match_data = payload(invalid,
                         [[0, 1], [0, 1]], "(a)")
    error = assert_raises(ArgumentError) { match_data.begin(0) }
    assert_match(/invalid byte sequence in UTF-8/, error.message)
    refute match_data.send(:__onibi_match_data_diagnostics__)[:character_cache_present]
  end

  def test_unknown_names_and_arity_match_mri
    mri = ::Regexp.new("(?<word>é)").match("é")
    onibi = payload("é", [[0, 2], [0, 2]], "(?<word>é)")
    %i[begin end offset match_length].each do |method|
      assert_differential(mri, onibi, method, "unknown")
      assert_raises(ArgumentError) { onibi.public_send(method) }
      assert_raises(ArgumentError) { onibi.public_send(method, 0, 1) }
    end
  end
end
