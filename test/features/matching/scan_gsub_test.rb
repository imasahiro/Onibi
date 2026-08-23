# frozen_string_literal: true

require "test_helper"

class ScanGsubTest < Minitest::Test
  def test_scan_returns_capture_values
    assert_equal [%w[a 1], %w[b 2]], Onibi::Regexp.new("([a-z])([0-9])").scan("a1 b2")
  end

  def test_scan_handles_empty_matches_without_looping
    assert_equal ["", "", ""], Onibi::Regexp.new("(?=a)").scan("aaa")
  end

  def test_gsub_supports_numbered_and_named_replacements
    assert_equal "b-a", Onibi::Regexp.new("([ab])-([ab])").gsub("a-b", '\\2-\\1')
    assert_equal "word", Onibi::Regexp.new("(?<value>word)").gsub("word", '\\k<value>')
  end

  def test_absence_scan_uses_the_common_vm_match_path
    assert_equal ["xxEN", "Dyy", ""], Onibi::Regexp.new("(?~END)").scan("xxENDyy")
  end
end
