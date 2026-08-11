# frozen_string_literal: true

require_relative "../../test_helper"

class RubyCodegenCasefoldTest < Minitest::Test
  def test_generated_literal_supports_variable_width_full_casefold
    ast = Onibi::Parser.new("ß").parse
    program = Onibi::Codegen::GeneratedProgram.ast(ast, options: ["ignorecase"])

    assert_equal true, program.search("SS", 0, capture: false)
    assert_equal true, program.search("ß", 0, capture: false)
  end
end
