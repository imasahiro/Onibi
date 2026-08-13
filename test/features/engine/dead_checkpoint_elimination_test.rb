# frozen_string_literal: true

require_relative "../../test_helper"

class DeadCheckpointEliminationTest < Minitest::Test
  def test_fixed_repeat_is_marked_checkpoint_free
    ast = Onibi::Parser.new("a{3}a").parse
    optimized = Onibi::Codegen::Optimization::Pipeline.default.call(
      ast, options: [], encoding: Encoding::UTF_8
    ).ast

    assert_equal :possessive, optimized.parts.first.mode
  end

  def test_fixed_repeat_preserves_matching
    regexp = Onibi::Regexp.new("a{3}a")

    assert regexp.match?("aaaa")
    refute regexp.match?("aaa")
  end
end
