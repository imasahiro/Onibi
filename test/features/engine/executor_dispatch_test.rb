# frozen_string_literal: true

require "test_helper"

class ExecutorDispatchTest < Minitest::Test
  def test_dynamic_fallback_is_visible
    regexp = Onibi::Regexp.new("(a)\\1")
    info = regexp.send(:__onibi_diagnostics__, "aa")
    assert_equal 2, info[:exec_kind]
    refute info[:regular_capable]
    assert_equal 1, info[:dynamic]
    assert_equal 1, info[:dfs]
    assert_equal 1, info[:fallback]
    assert_equal 2, info[:status]
  end

  def test_regular_unsupported_path_never_enters_dfs
    regexp = Onibi::Regexp.new("(a)")
    info = regexp.send(:__onibi_diagnostics__, "a")
    assert_equal 0, info[:exec_kind]
    assert info[:regular_capable]
    assert_equal 0, info[:dfs]
    assert_equal 0, info[:fallback]
  end

  def test_large_repeat_is_not_published_as_regular
    regexp = Onibi::Regexp.new("a{9}")
    info = regexp.send(:__onibi_diagnostics__, "aaaaaaaaa")
    refute info[:rseq]
    refute info[:regular_capable]
    refute_equal 0, info[:exec_kind]
    assert_equal 0, info[:dfs]
    assert_equal 2, info[:status]
  end

  def test_assertion_uses_tagged_executor
    regexp = Onibi::Regexp.new("^a")
    info = regexp.send(:__onibi_diagnostics__, "a")
    assert_equal 1, info[:exec_kind]
    refute info[:regular_capable]
    assert_equal 1, info[:tagged]
    assert_equal 1, info[:dfs]
  end
end
