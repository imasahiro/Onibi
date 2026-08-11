# frozen_string_literal: true

require_relative "../../test_helper"

class RubyCodegenAtomicTest < Minitest::Test
  def test_generated_atomic_group_and_possessive_quantifier
    atomic = Onibi::Codegen::GeneratedProgram.ast(Onibi::Parser.new("(?>a|ab)b").parse)
    possessive = Onibi::Codegen::GeneratedProgram.ast(Onibi::Parser.new("a++b").parse)

    assert_equal true, atomic.search("ab", 0, capture: false)
    assert_equal true, possessive.search("aab", 0, capture: false)
  end
end
