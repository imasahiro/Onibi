# frozen_string_literal: true

require_relative "../../test_helper"

class RubyCodegenAssertionTest < Minitest::Test
  def test_generated_lookahead_assertions_preserve_cursor
    positive = Onibi::Codegen::GeneratedProgram.ast(Onibi::Parser.new("(?=a)a").parse)
    negative = Onibi::Codegen::GeneratedProgram.ast(Onibi::Parser.new("(?!b)a").parse)

    assert_equal true, positive.search("a", 0, capture: false)
    assert_equal true, negative.search("a", 0, capture: false)
    assert_equal false, negative.search("ba", 0, capture: false)
  end

  def test_generated_fixed_width_lookbehind
    ast = Onibi::Parser.new("(?<=a)b").parse
    program = Onibi::Codegen::GeneratedProgram.ast(ast)

    assert_equal true, program.search("ab", 1, capture: false)
    assert_equal false, program.search("cb", 1, capture: false)
  end
end
