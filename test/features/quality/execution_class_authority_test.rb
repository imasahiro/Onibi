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
end
