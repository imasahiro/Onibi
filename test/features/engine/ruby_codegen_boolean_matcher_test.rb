# frozen_string_literal: true

require_relative "../../test_helper"

class RubyCodegenBooleanMatcherTest < Minitest::Test
  def test_boolean_surface_uses_generated_program_without_capture_result
    ast = Onibi::Parser.new("a+").parse
    matcher = Onibi::Codegen::BooleanMatcher.new(ast)

    assert matcher.match?("aaa")
    refute matcher.match?("bbb")
  end
end
