# frozen_string_literal: true

require_relative "../../test_helper"

class AutoPossessificationTest < Minitest::Test
  def test_pipeline_marks_disjoint_literal_quantifier_as_possessive
    ast = Onibi::Parser.new("a+b").parse
    optimized = Onibi::Codegen::Optimization::Pipeline.default.call(
      ast, options: [], encoding: Encoding::UTF_8
    ).ast

    assert_equal :possessive, optimized.parts.first.mode
  end

  def test_auto_possessification_preserves_matching
    regexp = Onibi::Regexp.new("a+b")

    assert regexp.match?("aaab")
    refute regexp.match?("aaac")
  end

  def test_overlapping_literal_quantifier_is_not_possessified
    ast = Onibi::Parser.new("a+a").parse
    optimized = Onibi::Codegen::Optimization::Pipeline.default.call(
      ast, options: [], encoding: Encoding::UTF_8
    ).ast

    assert_equal :greedy, optimized.parts.first.mode
  end
end
