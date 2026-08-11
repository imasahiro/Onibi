# frozen_string_literal: true

require "test_helper"

class BackreferenceTest < Minitest::Test
  def test_numbered_backreference_repeats_the_captured_text
    regexp = Onibi::Regexp.new("(ab)\\1")

    assert regexp.match?("zzabab")
    refute regexp.match?("zzabac")
    assert_equal "abab", regexp.match("zzabab")[0]
  end

  def test_named_backreference_repeats_the_named_capture
    regexp = Onibi::Regexp.new("(?<word>ab)\\k<word>")

    assert regexp.match?("abab")
    refute regexp.match?("abac")
  end
end
