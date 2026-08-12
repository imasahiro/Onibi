# frozen_string_literal: true

require_relative "../../test_helper"

class SwarMultiLiteralTest < Minitest::Test
  def test_multi_literal_prefilter_is_removed
    refute Onibi::Experimental::Swar.const_defined?(:MultiLiteralPrefilter, false)
  end

  def test_literal_alternation_prefilter_is_removed
    refute Onibi::Experimental::Swar.const_defined?(:LiteralAlternation, false)
  end

  def test_literal_alternation_falls_back_to_the_regular_search_plan
    ast = Onibi::Parser.new("sherlock|watson|moriarty").parse
    program = Onibi::Codegen::GeneratedProgram.ast(ast)

    refute program.respond_to?(:swar?)
    assert program.search("#{"x" * 100}moriarty", 0, capture: false)
  end

  def test_public_literal_alternation_still_agrees_with_mri
    pattern = "sherlock|watson|moriarty|adler"
    input = "elementary, watson; sherlock followed"
    expected = ::Regexp.new(pattern).match(input)
    actual = Onibi::Regexp.new(pattern).match(input)

    assert_equal expected[0], actual[0]
    assert_equal expected.offset(0), actual.offset(0)
  end
end
