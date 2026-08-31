# frozen_string_literal: true

require "test_helper"

class CaptureUseAnalysisTest < Minitest::Test
  def test_output_only_captures_have_no_semantic_register
    info = Onibi::Regexp.new("(a)").send(:__onibi_diagnostics__, "a")
    assert_equal 1, info[:capture_count]
    assert_equal 0, info[:semantic_capture_count]
  end

  def test_multiple_output_only_captures_have_no_semantic_registers
    info = Onibi::Regexp.new("(a)(b)").send(:__onibi_diagnostics__, "ab")
    assert_equal 2, info[:capture_count]
    assert_equal 0, info[:semantic_capture_count]
  end

  def test_backreference_capture_is_semantic
    info = Onibi::Regexp.new("(a)\\1").send(:__onibi_diagnostics__, "aa")
    assert_equal 1, info[:capture_count]
    assert_equal 1, info[:semantic_capture_count]
    assert_equal 2, info[:exec_kind]
  end
end
