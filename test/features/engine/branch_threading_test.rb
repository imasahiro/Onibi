# frozen_string_literal: true

require_relative "../../test_helper"

class BranchThreadingTest < Minitest::Test
  def test_pipeline_threads_a_common_literal_prefix
    ast = Onibi::Parser.new("ab|ac").parse
    optimized = Onibi::HybridAutomata::Optimization::Pipeline.default.call(
      ast, options: [], encoding: Encoding::UTF_8
    ).ast

    assert_instance_of Onibi::AST::Sequence, optimized
    assert_equal "a", optimized.parts.first.value
    assert_instance_of Onibi::AST::Alternation, optimized.parts.last
  end

  def test_branch_threading_preserves_alternation_semantics
    regexp = Onibi::Regexp.new("ab|ac")

    assert_equal "ab", regexp.match("ab")[0]
    assert_equal "ac", regexp.match("ac")[0]
    refute regexp.match?("ad")
  end
end
