# frozen_string_literal: true

require_relative "../../test_helper"

class LoopIdiomRecognitionTest < Minitest::Test
  def test_terminal_literal_plus_is_recognized_as_a_checkpoint_free_loop
    ast = Onibi::Parser.new("a+").parse
    optimized = Onibi::Codegen::Optimization::Pipeline.default.call(
      ast, options: [], encoding: Encoding::UTF_8
    ).ast

    assert_equal :possessive, optimized.parts.first.mode
  end

  def test_terminal_loop_preserves_greedy_matching
    regexp = Onibi::Regexp.new("a+")

    assert_equal "aaa", regexp.match("baaa").to_s
    refute regexp.match?("bbb")
  end
end
