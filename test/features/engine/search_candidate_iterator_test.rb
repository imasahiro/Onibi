# frozen_string_literal: true

require "test_helper"

class SearchCandidateIteratorTest < Minitest::Test
  def test_utf8_candidates_use_character_width_and_include_the_end_once
    subject = "あああ"
    regexp = Onibi::Regexp.new(".z")
    expected = ::Regexp.new(".z").match(subject)
    info = regexp.send(:__onibi_diagnostics__, subject)

    assert_nil expected
    assert_equal [0, 0], [info[:match_start], info[:match_end]]
    assert_equal 4, info[:regular_candidate_starts]
    assert_equal 0, info[:fallback]
    refute regexp.match?(subject)
  end

  def test_utf8_candidate_order_and_captures_match_mri
    subject = "あaz"
    pattern = "(.)z"
    regexp = Onibi::Regexp.new(pattern)
    expected = ::Regexp.new(pattern).match(subject)
    info = regexp.send(:__onibi_diagnostics__, subject)

    refute_nil expected
    assert_equal [expected.byteoffset(0).first, expected.byteoffset(0).last],
                 [info[:match_start], info[:match_end]]
    assert_equal [expected.byteoffset(1).first, expected.byteoffset(1).last],
                 info[:captures].first
    assert_equal 0, info[:fallback]
    assert_equal expected.to_a, regexp.match(subject).to_a
    assert_equal expected.begin(0), regexp.match(subject).begin(0)
    assert_equal expected.end(0), regexp.match(subject).end(0)
  end

  def test_requested_character_origin_matches_mri
    subject = "あaz"
    pattern = ".z"
    regexp = Onibi::Regexp.new(pattern)
    expected = ::Regexp.new(pattern).match(subject, 1)
    actual = regexp.match(subject, 1)

    refute_nil expected
    refute_nil actual
    assert_equal expected.byteoffset(0), actual.byteoffset(0)
    assert_equal expected.to_a, actual.to_a
    assert_equal ::Regexp.new(pattern).match?(subject, 1),
                 regexp.match?(subject, 1)
  end

  def test_byte_level_encoding_advances_one_byte
    subject = "\xFFa".b
    pattern = ".z".b
    regexp = Onibi::Regexp.new(pattern)
    expected = ::Regexp.new(pattern).match(subject)
    info = regexp.send(:__onibi_diagnostics__, subject)

    assert_nil expected
    assert_equal 3, info[:regular_candidate_starts]
    assert_equal 0, info[:fallback]
    refute regexp.match?(subject)
  end

  def test_forward_loop_has_no_byte_increment_for_character_candidates
    source = File.read(File.expand_path("../../../ext/onibi/match.c", __dir__))

    assert_includes source, "onibi_rseq_decode_character"
    assert_includes source, "candidate_valid = onibi_search_candidate_next"
    refute_match(/\bstart\+\+/, source)
    refute_match(/RSTRING_LEN\(str\)\s*\+\s*1/, source)
    refute_match(/\blength\s*\+\s*1/, source)
  end
end
