# frozen_string_literal: true

require_relative "../../test_helper"

class RegularRunByteScanTest < Minitest::Test
  def test_regular_run_matches_disjoint_ascii_runs
    run = Onibi::Codegen::RegularRun.new(%w[a-z 0-9])

    assert_equal [0, 6, []], run.search("abc123!", 0, capture: true)
    assert_equal false, run.search("abcXYZ", 0, capture: false)
  end

  def test_class_run_scans_a_matching_ascii_run_to_its_boundary
    scanner = Onibi::Experimental::Swar::ClassRun.new("a-z")

    assert_equal 3, scanner.scan_end("abc123", 0)
  end

  def test_dense_regular_run_matches_mri
    pattern = "[^,]+,+"
    input = "#{"abc123" * 32},"
    expected = ::Regexp.new(pattern).match(input)
    actual = Onibi::Regexp.new(pattern).match(input)

    assert_equal [expected[0], expected.offset(0)], [actual[0], actual.offset(0)]
  end

  def test_regular_run_supports_literal_and_class_components
    pattern = "ab[a-z]+[0-9]+"
    input = "xxabfoo123!"

    assert_equal ::Regexp.new(pattern).match?(input), Onibi::Regexp.new(pattern).match?(input)
    assert Onibi::Regexp.new(pattern).send(:codegen_program).search_plan.regular_run
  end

  def test_regular_run_supports_class_followed_by_literal
    pattern = "[0-9]+END"
    input = "xxabcEND!"

    assert_equal ::Regexp.new(pattern).match?(input), Onibi::Regexp.new(pattern).match?(input)
    assert Onibi::Regexp.new(pattern).send(:codegen_program).search_plan.regular_run
  end

  def test_common_prefix_alternation_uses_shared_candidate_path
    pattern = "foo[a-z]+|foo[0-9]+"
    input = "xxfooabc!"
    regexp = Onibi::Regexp.new(pattern)

    assert_equal ::Regexp.new(pattern).match(input).to_s, regexp.match(input).to_s
    refute regexp.send(:codegen_program).search_plan.regular_run
  end

  def test_single_literal_does_not_use_regular_run
    regexp = Onibi::Regexp.new("needle")

    refute regexp.send(:codegen_program).search_plan.regular_run
  end
end
