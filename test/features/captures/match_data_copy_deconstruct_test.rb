# frozen_string_literal: true

require "test_helper"

class MatchDataCopyDeconstructTest < Minitest::Test
  def payload(regexp, subject, ranges)
    Onibi::MatchData.send(:__onibi_new__, regexp, subject, ranges)
  end

  def test_dup_and_clone_copy_registers_and_character_cache
    regexp = Onibi::Regexp.new("(?<word>é)(?<empty>)")
    match_data = payload(regexp, "é", [[0, 2], [0, 2], [2, 2]])
    assert_equal 0, match_data.begin(:word)

    duplicate = match_data.dup
    clone = match_data.clone
    assert_equal match_data.to_a, duplicate.to_a
    assert_equal match_data.to_a, clone.to_a
    assert duplicate.send(:__onibi_match_data_diagnostics__)[:character_cache_present]
    assert clone.send(:__onibi_match_data_diagnostics__)[:character_cache_present]
    refute_same match_data, duplicate
    refute_same match_data, clone
  end

  def test_copy_preserves_freeze_and_clone_preserves_singleton_methods
    regexp = Onibi::Regexp.new("(a)")
    match_data = payload(regexp, "a", [[0, 1], [0, 1]])
    def match_data.marker
      :marker
    end

    match_data.freeze
    duplicate = match_data.dup
    clone = match_data.clone
    refute duplicate.frozen?
    assert clone.frozen?
    refute duplicate.respond_to?(:marker)
    assert_equal :marker, clone.marker
  end

  def test_deconstruct_returns_fresh_capture_values
    regexp = Onibi::Regexp.new("(?<word>a)(?<missing>b)?(?<empty>)")
    match_data = payload(regexp, "a", [[0, 1], [0, 1], [-1, -1], [1, 1]])

    first = match_data.deconstruct
    second = match_data.deconstruct
    assert_equal ["a", nil, ""], first
    refute_same first, second
    first[0].replace("changed")
    assert_equal "a", match_data[1]
  end

  def test_deconstruct_keys_returns_symbol_keys_and_omits_unknown_names
    regexp = Onibi::Regexp.new("(?<word>a)(?<missing>b)?(?<empty>)")
    match_data = payload(regexp, "a", [[0, 1], [0, 1], [-1, -1], [1, 1]])

    assert_equal({ word: "a", missing: nil, empty: "" },
                 match_data.deconstruct_keys(nil))
    assert_equal({ empty: "", word: "a" },
                 match_data.deconstruct_keys(%i[empty word unknown word]))
    assert_raises(TypeError) { match_data.deconstruct_keys({}) }
    assert_raises(TypeError) { match_data.deconstruct_keys(:word) }
    assert_raises(TypeError) { match_data.deconstruct_keys(["word"]) }
  end
end
