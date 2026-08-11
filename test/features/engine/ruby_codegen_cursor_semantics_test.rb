# frozen_string_literal: true

require_relative "../../test_helper"

class RubyCodegenCursorSemanticsTest < Minitest::Test
  def test_generated_linebreak_consumes_crlf_as_one_linebreak
    program = Onibi::Codegen::GeneratedProgram.ast(Onibi::Parser.new("\\R").parse)

    assert_equal true, program.search("\r\n", 0, capture: false)
  end

  def test_generated_start_match_anchor_uses_immutable_search_origin
    program = Onibi::Codegen::GeneratedProgram.ast(Onibi::Parser.new("\\Ga").parse)

    assert_equal false, program.search("ba", 0, capture: false)
    assert_equal true, program.search("ba", 1, capture: false)
  end
end
