# frozen_string_literal: true

require "test_helper"

class CompilerExceptionSafetyTest < Minitest::Test
  CORPUS = [
    ["a|bc", "xbc"],
    ["(?<x>a|b)*", "abba"],
    ["[a-c]+\\z", "zabc"],
    ["(ab){1,3}?", "ababx"]
  ].freeze

  def test_each_compiler_and_lowering_pass_cleans_up_on_injected_failure
    regexp = Onibi::Regexp.new("(?<x>a|[b-d]){1,3}?")

    3.times do
      (1..15).each do |phase|
        diagnostics = regexp.send(:__onibi_compile_failure_diagnostics__, phase)

        assert diagnostics.fetch(:raised), "failure phase #{phase} did not raise"
        assert_equal 0, diagnostics.fetch(:allocations_before),
                     "failure phase #{phase} started with a stale owner"
        assert_equal diagnostics.fetch(:allocations_before),
                     diagnostics.fetch(:allocations_after),
                     "failure phase #{phase} leaked an owned C allocation"

        pattern, subject = CORPUS.fetch((phase - 1) % CORPUS.length)
        assert_match_result_equal(pattern, subject)
      end
      GC.start
    end
  end

  def test_compiler_has_no_encoding_tls
    root = File.expand_path("../../..", __dir__)
    source = File.read(File.join(root, "ext/onibi/onibi_common.c"))

    refute_includes source, "onibi_compile_encoding"
  end

  private

  def assert_match_result_equal(pattern, subject)
    expected = ::Regexp.new(pattern).match(subject)
    actual = Onibi::Regexp.new(pattern).match(subject)

    assert_equal expected&.to_a, actual&.to_a, pattern
    return unless expected

    expected.length.times do |index|
      assert_equal expected.bytebegin(index), actual.bytebegin(index), pattern
      assert_equal expected.byteend(index), actual.byteend(index), pattern
    end
  end
end
