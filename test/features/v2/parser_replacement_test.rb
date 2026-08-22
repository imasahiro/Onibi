# frozen_string_literal: true

require "test_helper"

class V2ParserReplacementTest < Minitest::Test
  def test_parser_entry_point_accepts_v2_global_inline_options
    expected = Onibi::V2::Parser.parse("(?imx)cat").ast

    assert_equal expected, Onibi::Parser.new("(?imx)cat").parse
  end
end
