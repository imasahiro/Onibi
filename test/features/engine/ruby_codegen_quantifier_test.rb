# frozen_string_literal: true

require_relative "../../test_helper"

class RubyCodegenQuantifierTest < Minitest::Test
  def test_generated_greedy_and_bounded_quantifiers
    plus = Onibi::Codegen::GeneratedProgram.ast(Onibi::Parser.new("a+").parse)
    bounded = Onibi::Codegen::GeneratedProgram.ast(Onibi::Parser.new("a{2,3}").parse)

    assert_equal true, plus.search("aaa", 0, capture: false)
    assert_equal true, bounded.search("aaa", 0, capture: false)
    assert_equal false, bounded.search("a", 0, capture: false)
  end

  def test_empty_body_quantifier_terminates
    ast = Onibi::Parser.new("(?:){0,}").parse
    program = Onibi::Codegen::GeneratedProgram.ast(ast)

    assert_equal true, program.search("", 0, capture: false)
  end

  def test_greedy_quantifier_backtracks_for_a_following_literal
    ast = Onibi::Parser.new("a.*z").parse
    program = Onibi::Codegen::GeneratedProgram.ast(ast)

    assert_equal true, program.search("a-middle-z", 0, capture: false)
  end

  def test_zero_repeat_keeps_the_unmatched_capture_slot
    ast = Onibi::Parser.new("(a)?c").parse
    program = Onibi::Codegen::GeneratedProgram.ast(ast)

    assert_equal [0, 1, [nil]], program.search("c", 0, capture: true)
  end
end
