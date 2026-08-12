# frozen_string_literal: true

require_relative "../../test_helper"

class PredicateRegistryTest < Minitest::Test
  def test_repeated_predicate_keys_share_one_index
    registry = Onibi::Codegen::PredicateRegistry.new
    key = ["a-z", false]

    assert_equal 0, registry.register(key)
    assert_equal 0, registry.register(key)
    assert_equal [key], registry.entries
  end

  def test_equivalent_ascii_ranges_share_one_index
    registry = Onibi::Codegen::PredicateRegistry.new

    assert_equal 0, registry.register(["a-c", false])
    assert_equal 0, registry.register(["abc", false])
    assert_equal [["a-c", false]], registry.entries
  end

  def test_equivalent_generated_classes_share_one_table
    ast = Onibi::Parser.new("[a-c][abc]").parse
    program = Onibi::Codegen::GeneratedProgram.ast(ast)

    assert_equal ::Regexp.new("[a-c][abc]").match?("ab"), program.search("ab", 0, capture: false)
    assert_equal 1, program.source.scan("TableRegistry.fetch").length
  end
end
