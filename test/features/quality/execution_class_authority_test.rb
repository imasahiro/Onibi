# frozen_string_literal: true

require "test_helper"

class ExecutionClassAuthorityTest < Minitest::Test
  CASES = {
    "(a)" => 0,
    "a{2}" => 0,
    "(?=a)b" => 1,
    "(?<x>a)\\g<x>" => 2
  }.freeze

  def test_verified_gir_class_is_the_execution_class_authority
    CASES.each do |pattern, expected_kind|
      regexp = Onibi::Regexp.new(pattern)
      info = regexp.send(:__onibi_diagnostics__, "aab")

      assert info.fetch(:rseq), pattern
      assert_equal expected_kind, info.fetch(:exec_kind), pattern
      assert_equal expected_kind == 2, !Onibi::Regexp.linear_time?(pattern), pattern
    end
  end

  def test_token_metadata_does_not_assign_execution_class
    source = File.read(File.join(PROJECT_ROOT, "ext", "onibi", "rseq.c"))
    token_features = source[/static void\s+onibi_token_features\(.*?^}\n/m]
    initialize = source[/static VALUE\s+onibi_initialize\(.*?^}\n/m]

    refute_nil token_features
    refute_nil initialize
    refute_includes token_features, "execution_kind"
    refute_includes token_features, "execution_flags"
    assert_includes initialize, "obj->rseq_view.header->exec_kind"
    refute_match(/FEATURE_SUBROUTINE.*execution_kind/m, initialize)
  end

  def test_unsupported_compilation_uses_mri_linear_time_boundary
    pattern = "\\X"
    expected = ::Regexp.linear_time?(::Regexp.new(pattern))

    assert_equal expected, Onibi::Regexp.linear_time?(pattern)
  end

  def test_uncompiled_patterns_have_no_native_execution_class
    unsupported = Onibi::Regexp.new("\\X")
    unsupported_info = unsupported.send(:__onibi_diagnostics__, "")

    refute unsupported_info.fetch(:rseq)
    assert_nil unsupported_info.fetch(:exec_kind)
    assert_equal :unsupported, unsupported_info.fetch(:compile_error_kind)
    assert_equal :grapheme, unsupported_info.fetch(:fallback_reason)

    noencoding = Onibi::Regexp.new("a", Onibi::Regexp::NOENCODING)
    noencoding_info = noencoding.send(:__onibi_diagnostics__, "a")

    refute noencoding_info.fetch(:rseq)
    assert_nil noencoding_info.fetch(:exec_kind)
    assert_equal :ok, noencoding_info.fetch(:compile_error_kind)
    assert_equal :noencoding, noencoding_info.fetch(:fallback_reason)
  end
end
