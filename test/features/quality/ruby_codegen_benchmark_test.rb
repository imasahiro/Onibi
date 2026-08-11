# frozen_string_literal: true

require_relative "../../test_helper"

class RubyCodegenBenchmarkTest < Minitest::Test
  def test_generated_and_legacy_fixture_outputs_are_equivalent
    regexp = Onibi::Regexp.new("a+b")
    ast = Onibi::Parser.new("a+b").parse
    generated = Onibi::Codegen::BooleanMatcher.new(ast)
    inputs = %w[ab aaab b aaa]

    legacy = inputs.map { |input| regexp.match?(input) }
    codegen = inputs.map { |input| generated.match?(input) }

    assert_equal legacy, codegen
  end
end
