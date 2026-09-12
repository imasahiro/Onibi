# frozen_string_literal: true

require "test_helper"

class ExecutionArenaTest < Minitest::Test
  def test_regular_buffers_grow_once_and_reuse_for_candidate_starts
    regexp = Onibi::Regexp.new("([^z])z")
    info = regexp.send(:__onibi_diagnostics__, "x" * 20)

    assert_equal 0, info[:status]
    assert_equal 0, info[:exec_kind]
    assert_equal 21, info[:regular_candidate_starts]
    assert_equal 2, info[:regular_buffer_grows]
    assert_equal 40, info[:regular_buffer_reuses]
  end

  def test_production_executor_sources_have_no_variable_stack_allocations
    root = File.expand_path("../../../ext/onibi", __dir__)
    %w[exec_dynamic.c match.c rseq_runtime.c].each do |name|
      source = File.read(File.join(root, name))
      refute_match(/\b(?:ALLOCA_N|alloca)\s*\(/, source, name)
    end
  end
end
