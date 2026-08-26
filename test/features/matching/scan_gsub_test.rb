# frozen_string_literal: true

require "test_helper"

class ScanGsubTest < Minitest::Test
  def test_scan_returns_capture_values
    assert_equal [%w[a 1], %w[b 2]], Onibi::Regexp.new("([a-z])([0-9])").scan("a1 b2")
  end

  def test_scan_handles_empty_matches_without_looping
    assert_equal ["", "", ""], Onibi::Regexp.new("(?=a)").scan("aaa")
    assert_equal [""], Onibi::Regexp.new("(?=a)").scan("ba")
    assert_equal ["", ""], Onibi::Regexp.new("").scan("a")
  end

  def test_gsub_supports_numbered_and_named_replacements
    assert_equal "b-a", Onibi::Regexp.new("([ab])-([ab])").gsub("a-b", '\\2-\\1')
    assert_equal "word", Onibi::Regexp.new("(?<value>word)").gsub("word", '\\k<value>')
    assert_equal "bXa", Onibi::Regexp.new("(?=a)").gsub("ba", "X")
    assert_equal "XaX", Onibi::Regexp.new("").gsub("a", "X")
  end

  def test_numeric_replacements_are_empty_when_named_captures_exist
    regexp = Onibi::Regexp.new("(?<first>a)(?<second>b)")
    assert_equal "-", regexp.gsub("ab", '\\1-\\2')
    assert_equal "a-b", regexp.gsub("ab", '\\k<first>-\\k<second>')
  end

  def test_absence_scan_uses_the_common_vm_match_path
    assert_equal ["xxEN", "Dyy", ""], Onibi::Regexp.new("(?~END)").scan("xxENDyy")
  end
end
