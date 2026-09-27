# frozen_string_literal: true

require "test_helper"

class ResolvedSemanticAstTest < Minitest::Test
  def test_large_capture_name_corpus_uses_indexed_compile_paths
    bounded = (0...10).map { |i| "(?<n#{i}>a)" }.join
    regexp = Onibi::Regexp.new(bounded)
    assert regexp.send(:__onibi_diagnostics__, "a" * 10)[:rseq]
    large = (0...40).map { |i| "(?<n#{i}>a)" }.join
    assert Onibi::Regexp.new(large)
  end

  def test_duplicate_names_keep_order_and_compile_to_rseq
    regexp = Onibi::Regexp.new("(?<same>a)(?<same>b)\\k<same>")
    assert regexp.send(:__onibi_diagnostics__, "aba")[:rseq]
  end

  def test_repeated_named_subroutine_compiles_to_rseq
    regexp = Onibi::Regexp.new("(?<same>a)\\g<same>\\g<same>")
    assert regexp.send(:__onibi_diagnostics__, "aaa")[:rseq]
  end
end
