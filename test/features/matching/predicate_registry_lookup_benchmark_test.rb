# frozen_string_literal: true

require_relative "../../test_helper"

class PredicateRegistryLookupBenchmarkTest < Minitest::Test
  def test_repeated_generated_classes_share_one_table
    pattern = "[a-z][0-9][a-z][0-9][a-z]"
    program = Onibi::Codegen::GeneratedProgram.ast(Onibi::Parser.new(pattern).parse)

    assert_equal 2, program.source.scan("TableRegistry.fetch").length
    assert_equal ::Regexp.new(pattern).match?("a1b2c"), Onibi::Regexp.new(pattern).match?("a1b2c")
  end
end
