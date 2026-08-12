# frozen_string_literal: true

require_relative "../../test_helper"

class RubyCodegenMatchAdapterTest < Minitest::Test
  def test_generated_offsets_build_existing_match_data
    ast = Onibi::Parser.new("(a)(?<word>b)").parse
    program = Onibi::Codegen::GeneratedProgram.ast(ast)
    result = program.search("ab", 0, capture: true)
    regexp = Onibi::Regexp.new("ab")
    match = Onibi::Codegen::MatchAdapter.build(result, "ab", regexp, "word" => 2)

    assert_equal "ab", match[0]
    assert_equal %w[a b], match.captures
    assert_equal [[0, 2], [0, 1], [1, 2]], [match.offset(0), match.offset(1), match.offset(2)]
  end

  def test_ascii_input_uses_direct_string_slices_without_materializing_chars
    ast = Onibi::Parser.new("(a)(b)").parse
    program = Onibi::Codegen::GeneratedProgram.ast(ast)
    result = program.search("ab", 0, capture: true)
    input = StringSliceProbe.new("ab")
    regexp = Onibi::Regexp.new("ab")

    match = Onibi::Codegen::MatchAdapter.build(result, input, regexp)

    assert_equal "ab", match[0]
    assert_equal %w[a b], match.captures
    assert_equal 0, input.chars_calls
  end

  def test_multibyte_input_uses_input_view_slices
    ast = Onibi::Parser.new("(あ)(b)").parse
    program = Onibi::Codegen::GeneratedProgram.ast(ast)
    result = program.search("あb", 0, capture: true)
    regexp = Onibi::Regexp.new("あb")

    match = Onibi::Codegen::MatchAdapter.build(result, "あb", regexp)

    assert_equal "あb", match[0]
    assert_equal %w[あ b], match.captures
  end

  class StringSliceProbe < String
    attr_reader :chars_calls

    def initialize(value)
      super
      @chars_calls = 0
    end

    def chars
      @chars_calls += 1
      raise "full input chars materialization is not allowed"
    end
  end
end
