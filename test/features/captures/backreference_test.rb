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

  def test_repeated_class_backreference_runs_in_the_vm
    regexp = Onibi::Regexp.new("([a-z]+)-\\1")

    assert_equal "echo-echo", regexp.match("echo-echo")[0]
  end
end
