# frozen_string_literal: true

require_relative "../../test_helper"

class RedundantPredicateEliminationTest < Minitest::Test
  def test_pipeline_eliminates_repeated_pure_assertions
    ast = Onibi::Parser.new("(?=a)(?=a)a").parse
    optimized = Onibi::Codegen::Optimization::Pipeline.default.call(
      ast, options: [], encoding: Encoding::UTF_8
    ).ast

    assert_equal 2, optimized.parts.length
    assert_equal :positive, optimized.parts.first.kind
  end

  def test_redundant_predicate_elimination_preserves_matching
    regexp = Onibi::Regexp.new("(?=a)(?=a)a")

    assert regexp.match?("a")
    refute regexp.match?("b")
  end
end
