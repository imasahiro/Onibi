# frozen_string_literal: true

require_relative "../../test_helper"

class RubyCodegenConcurrencyTest < Minitest::Test
  def test_one_generated_program_supports_concurrent_calls
    ast = Onibi::Parser.new("a+").parse
    program = Onibi::Codegen::GeneratedProgram.ast(ast)
    results = 8.times.map do |index|
      Thread.new { program.search("a" * (index + 1), 0, capture: false) }
    end.map(&:value)

    assert_equal Array.new(8, true), results
  end
end
