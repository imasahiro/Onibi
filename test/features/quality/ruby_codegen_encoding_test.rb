# frozen_string_literal: true

require_relative "../../test_helper"

class RubyCodegenEncodingTest < Minitest::Test
  def test_generated_literal_handles_utf8_and_binary_inputs
    utf8 = Onibi::Codegen::GeneratedProgram.ast(Onibi::Parser.new("あ").parse)

    assert utf8.search("あ", 0, capture: false)
    assert_equal 1, Onibi::InputView.new("\xFF".b).character_length
  end

  def test_input_view_preserves_multibyte_byte_offsets
    view = Onibi::InputView.new("aあ")

    assert_equal [0, 1, 4], [view.byte_offset(0), view.byte_offset(1), view.byte_offset(2)]
  end
end
