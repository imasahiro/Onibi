# frozen_string_literal: true

require "test_helper"

class RuntimeOutcomeTest < Minitest::Test
  def test_input_ineligibility_is_typed_and_matches_mri
    regexp = Onibi::Regexp.new("ss\\b", Regexp::IGNORECASE)
    subject = "😀ß"
    info = regexp.send(:__onibi_diagnostics__, subject)

    assert_equal Regexp.new("ss\\b", Regexp::IGNORECASE).match?(subject),
                 regexp.match?(subject)
    assert_equal 2, info[:status]
    assert_equal 1, info[:fallback]
    assert_equal :input_ineligible, info[:fallback_reason]
    assert_equal :none, info[:executor_error_kind]
  end

  def test_executor_failure_is_typed_as_internal_error
    info = Onibi::Regexp.new("a").send(
      :__onibi_internal_error_diagnostics__, "a"
    )

    assert_equal(-1, info[:status])
    assert_equal :unexpected, info[:executor_error_kind]
    assert_equal :none, info[:fallback_reason]
    assert_equal 0, info[:fallback]
  end

  def test_executor_sources_cannot_select_mri_fallback
    root = File.expand_path("../../..", __dir__)
    executor_sources = %w[exec_dynamic.c rseq_runtime.c].map do |file|
      File.read(File.join(root, "ext", "onibi", file))
    end.join

    refute_match(/return\s+ONIBI_EXEC_STATUS_FALLBACK/, executor_sources)
    assert_includes File.read(File.join(root, "ext", "onibi", "match.c")),
                    "ONIBI_RUNTIME_FALLBACK_INPUT_INELIGIBLE"
  end
end
