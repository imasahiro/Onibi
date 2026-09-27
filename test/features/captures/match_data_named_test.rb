# frozen_string_literal: true

require "test_helper"

class MatchDataNamedTest < Minitest::Test
  def payload(source, subject)
    mri_regexp = ::Regexp.new(source)
    mri = mri_regexp.match(subject)
    ranges = mri.length.times.map do |index|
      begin_offset, end_offset = mri.offset(index)
      if begin_offset.nil?
        [-1, -1]
      else
        [subject[0, begin_offset].bytesize, subject[0, end_offset].bytesize]
      end
    end
    regexp = Onibi::Regexp.new(source)
    match_data = Onibi::MatchData.send(:__onibi_new__, regexp, subject, ranges)
    [mri, match_data]
  end

  def result(callable)
    [:value, callable.call]
  rescue StandardError => e
    [:error, e.class, e.message]
  end

  def assert_differential(mri, onibi)
    assert_equal result(-> { yield mri }), result(-> { yield onibi })
  end

  def test_named_string_and_symbol_lookup_matches_mri_for_duplicate_names
    [
      ["(?<word>a)(?<word>b)?", "a"],
      ["(?<word>a)(?<word>b)?", "ab"],
      ["(?<word>a)?(?<word>b)?", "x"],
      ["(?<empty>)(?<missing>a)?", ""]
    ].each do |source, subject|
      mri, onibi = payload(source, subject)
      ["word", :word, "empty", :empty, "missing", :missing].each do |name|
        assert_differential(mri, onibi) { |match_data| match_data[name] }
        assert_differential(mri, onibi) do |match_data|
          match_data[name, nil]
        end
      end
    end
  end

  def test_unknown_and_encoding_incompatible_names_match_mri_errors
    mri, onibi = payload("(?<word>a)", "a")
    names = [
      "unknown",
      :unknown,
      "a\"b",
      "x\\y",
      '#@foo',
      '#$foo',
      "\#{foo}",
      '\\#@foo',
      '\\#$foo',
      '\\#{foo}',
      'a#@foo',
      'a#$foo',
      "a\#{foo}",
      'a\\#@foo',
      'a\\#$foo',
      'a\\#{foo}',
      "a\nb",
      "a\tb",
      "a\0b",
      "\x01",
      "\x7f",
      "é"
    ]
    names.each do |name|
      assert_differential(mri, onibi) { |match_data| match_data[name] }
    end

    ["\x01", "\x7f", "\x80", "\xC3\xA9", "\xFF"].each do |bytes|
      incompatible = bytes.b
      assert_differential(mri, onibi) do |match_data|
        match_data[incompatible]
      end
    end
  end

  def test_names_and_named_captures_match_mri_and_support_keywords
    [
      ["abc", "abc"],
      ["(?<word>a)(?<word>b)?", "a"],
      ["(?<empty>)(?<missing>a)?", ""]
    ].each do |source, subject|
      mri, onibi = payload(source, subject)
      assert_equal mri.names, onibi.names
      assert_equal mri.named_captures, onibi.named_captures
      assert_equal mri.named_captures(symbolize_names: true),
                   onibi.named_captures(symbolize_names: true)
      assert_equal mri.named_captures(**{}), onibi.named_captures(**{})
    end
  end

  def test_named_captures_keyword_and_arity_errors_match_mri
    mri, onibi = payload("(?<word>a)", "a")
    [
      ->(match_data) { match_data.named_captures(1) },
      ->(match_data) { match_data.named_captures({ symbolize_names: true }) },
      ->(match_data) { match_data.named_captures(foo: true) }
    ].each do |callable|
      assert_differential(mri, onibi) { |match_data| callable.call(match_data) }
    end
  end

  def test_named_metadata_returns_fresh_isolated_values
    _mri, match_data = payload("(?<word>a)(?<word>b)", "ab")

    names = match_data.names
    later_names = match_data.names
    refute_same names, later_names
    refute_same names.first, later_names.first
    refute names.frozen?
    refute names.first.frozen?
    names.first << "_changed"
    names << "new"

    captures = match_data.named_captures
    later_captures = match_data.named_captures
    refute_same captures, later_captures
    refute_same captures["word"], later_captures["word"]
    assert captures.keys.first.frozen?
    refute captures.frozen?
    refute captures["word"].frozen?
    captures["word"] << "_changed"
    captures["new"] = [1]

    assert_equal ["word"], match_data.names
    assert_equal({ "word" => "b" }, match_data.named_captures)
    assert_equal({ word: "b" }, match_data.named_captures(symbolize_names: true))
  end

  def test_named_values_are_fresh_and_subject_mutation_does_not_change_result
    subject = String.new("xxéyy")
    _mri, match_data = payload("(?<word>é)", subject)
    subject.replace("changed")
    GC.start
    GC.compact

    first = match_data["word"]
    first << "_changed"
    assert_equal "é", match_data["word"]
    assert_equal({ "word" => "é" }, match_data.named_captures)
    assert_equal Encoding::UTF_8, match_data.names.first.encoding
  end

  def test_non_name_objects_keep_numeric_coercion
    mri, onibi = payload("(a)", "a")
    integer_like = Object.new
    integer_like.define_singleton_method(:to_int) { 1 }
    assert_differential(mri, onibi) do |match_data|
      match_data[integer_like]
    end
  end
end
