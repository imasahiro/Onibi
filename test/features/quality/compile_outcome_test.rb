# frozen_string_literal: true

require "test_helper"

class CompileOutcomeTest < Minitest::Test
  def test_initialization_records_only_explicit_unsupported_fallback
    regexp = Onibi::Regexp.new("\\u{1234}")
    diagnostics = regexp.send(:__onibi_diagnostics__, "")

    assert_equal :unsupported, diagnostics.fetch(:compile_error_kind)
    assert_equal :escape, diagnostics.fetch(:unsupported_reason)
    assert_equal :escape, diagnostics.fetch(:fallback_reason)
    refute diagnostics.fetch(:rseq)
  end

  def test_initialization_error_releases_tokens_before_reraising
    error = assert_raises(Onibi::RegexpError) do
      # MRI accepts this comment, but the Onibi parser rejects it. This
      # reaches the protected compiler path after tokenization succeeds.
      Onibi::Regexp.new("(?#x)a")
    end

    assert_equal "unexpected token in expression", error.message

    root = File.expand_path("../../..", __dir__)
    source = File.read(File.join(root, "ext/onibi/rseq.c"))
    decision = source[/if \(!onibi_compile_outcome_select_fallback.*?rb_jump_tag\(program_state\);/m]

    refute_nil decision
    assert_match(/onibi_token_vector_free\(&tokens\);\s*rb_jump_tag\(program_state\);/m,
                 decision)
  end

  def test_internal_failure_re_raises_through_the_initialization_decision
    regexp = Onibi::Regexp.new("a")
    error = assert_raises(Onibi::RegexpError) do
      regexp.send(:__onibi_compile_outcome_internal_diagnostics__)
    end

    assert_equal "injected internal compile failure", error.message
    diagnostics = regexp.send(:__onibi_diagnostics__, "a")
    assert_equal :ok, diagnostics.fetch(:compile_error_kind)
    assert_predicate diagnostics.fetch(:rseq), :itself
  end

  def test_valid_unsupported_features_keep_typed_fallback_reasons
    {
      "\\M-\\C-?".b => :meta_escape,
      "\\u{1234}" => :escape,
      "\\X" => :grapheme,
      "[\\R]" => :class,
      "a++a" => :possessive,
      "(a*)++" => :possessive
    }.each do |pattern, reason|
      regexp = Onibi::Regexp.new(pattern)
      diagnostics = regexp.send(:__onibi_diagnostics__, "")

      assert_equal :unsupported, diagnostics.fetch(:compile_error_kind), pattern
      assert_equal reason, diagnostics.fetch(:unsupported_reason), pattern
      assert_equal reason, diagnostics.fetch(:fallback_reason), pattern
      refute diagnostics.fetch(:rseq), pattern
    end
  end

  def test_mri_valid_unsupported_posix_classes_keep_typed_fallback_reasons
    %w[graph print].each do |property|
      pattern = "[[:#{property}:]]"
      Regexp.new(pattern)
      regexp = Onibi::Regexp.new(pattern)
      diagnostics = regexp.send(:__onibi_diagnostics__, "")

      assert_equal :unsupported, diagnostics.fetch(:compile_error_kind), pattern
      assert_equal :class, diagnostics.fetch(:unsupported_reason), pattern
      assert_equal :class, diagnostics.fetch(:fallback_reason), pattern
      refute diagnostics.fetch(:rseq), pattern
    end
  end
end
