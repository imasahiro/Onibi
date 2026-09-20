# frozen_string_literal: true

require "test_helper"

# These checks record the TASK-42C2 boundary. They do not define future support.
class BackreferenceBoundaryAuditTest < Minitest::Test
  def test_native_success_and_miss_have_different_backreference_effects
    regexp = Onibi::Regexp.new("(a)")
    /prior/.match("prior")
    before = $~
    assert_instance_of Onibi::MatchData, regexp.match("ba")
    assert_same before, $~
    assert_same before, Onibi::Regexp.last_match
    assert_equal "prior", Onibi::Regexp.last_match(0)
    assert_nil regexp.match("z")
    assert_nil $~
  end

  def test_match_question_preserves_state_on_native_and_fallback_paths
    ["(a)", "\\X"].each do |pattern|
      regexp = Onibi::Regexp.new(pattern)
      /prior/.match("prior")
      before = $~
      assert regexp.match?("a")
      refute regexp.match?("")
      assert_same before, $~
    end
  end

  def test_explicit_fallback_returns_mri_match_data
    regexp = Onibi::Regexp.new("\\X")
    match = regexp.match("a")
    assert_instance_of ::MatchData, match
    assert_same match, $~
    regexp.match("a") { |value| assert_instance_of ::MatchData, value }
  end

  def test_case_equal_and_tilde_use_native_results_without_mri_match
    regexp = Onibi::Regexp.new("a")
    original = ::Regexp.instance_method(:match)
    ::Regexp.define_method(:match) { |*| raise "MRI match called" }
    $_ = "a"
    assert_instance_of Onibi::MatchData, regexp.match("a")
    assert regexp.match?("a")
    assert_equal true, regexp === "a"
    assert_equal 0, ~regexp
  ensure
    ::Regexp.define_method(:match, original) if original
    $_ = nil
  end

  def test_string_callers_reject_the_custom_regexp
    regexp = Onibi::Regexp.new("a")
    %i[scan match match? split].each do |method|
      assert_raises(TypeError) { "a".public_send(method, regexp) }
    end
    %i[sub gsub].each do |method|
      assert_raises(TypeError) { "a".public_send(method, regexp, "x") }
    end
    assert_equal 0, regexp =~ "a"
    assert_equal 0, "a" =~ regexp
    assert_raises(TypeError) { "a"[regexp] }
  end

  def test_scan_and_gsub_do_not_publish_native_match_data
    regexp = Onibi::Regexp.new("(a)")
    /prior/.match("prior")
    before = $~
    yielded = []
    assert_equal [["a"], ["a"]], regexp.scan("aba") { |value| yielded << value }
    assert_empty yielded
    assert_equal "xbx", regexp.gsub("aba") { |value|
      assert_equal "a", value
      assert_same before, $~
      "x"
    }
    assert_same before, $~
    assert_equal "xbx", "aba".gsub(/(a)/, "x")
  end
end
