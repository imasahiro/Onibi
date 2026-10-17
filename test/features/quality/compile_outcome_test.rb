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
    diagnostic = {}
    error = assert_raises(Onibi::RegexpError) do
      Onibi::Regexp.send(
        :__onibi_initialization_failure_diagnostics__, "a", diagnostic
      )
    end

    assert_equal "injected internal initialization failure", error.message
    assert diagnostic.fetch(:failure_injected)
    assert_operator diagnostic.fetch(:token_count_before_cleanup), :>, 0
    assert_equal 0, diagnostic.fetch(:token_count_after_cleanup)
    assert diagnostic.fetch(:token_storage_released)
    assert_equal :internal, diagnostic.fetch(:compile_error_kind)
    refute diagnostic.fetch(:fallback_selected)

    regexp = Onibi::Regexp.new("a")
    assert_equal ["a"], regexp.match("a").to_a
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
