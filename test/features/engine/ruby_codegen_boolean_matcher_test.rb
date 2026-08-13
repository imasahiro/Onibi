# frozen_string_literal: true

require_relative "../../test_helper"

class RubyCodegenBooleanMatcherTest < Minitest::Test
  def test_boolean_surface_uses_generated_program_without_capture_result
    ast = Onibi::Parser.new("a+").parse
    matcher = Onibi::Codegen::BooleanMatcher.new(ast)

    assert matcher.match?("aaa")
    refute matcher.match?("bbb")
  end

  def test_captureless_boolean_program_does_not_allocate_capture_array
    ast = Onibi::Parser.new("a+").parse
    program = Onibi::Codegen::GeneratedProgram.ast(ast)

    refute_includes program.source, "Array.new(0)"
    assert program.search("aaa", 0, capture: false)
  end

  def test_boolean_program_lazily_allocates_captures_when_group_is_not_live
    ast = Onibi::Parser.new("(a+)").parse
    program = Onibi::Codegen::GeneratedProgram.ast(ast)

    assert_includes program.source, "capture ?Array.new(1):nil"
    assert program.search("aaa", 0, capture: false)
  end

  def test_boolean_program_keeps_capture_state_for_backreferences
    ast = Onibi::Parser.new("(a)\\1").parse
    program = Onibi::Codegen::GeneratedProgram.ast(ast)

    assert_includes program.source, "captures=Array.new(1)"
    assert program.search("aa", 0, capture: false)
    refute program.search("ab", 0, capture: false)
  end

  def test_boolean_program_eliminates_dead_trailing_capture_state
    ast = Onibi::Parser.new("(a)(b)\\1").parse
    program = Onibi::Codegen::GeneratedProgram.ast(ast)

    assert_includes program.source, "capture ? Array.new(2) : Array.new(1)"
    assert_match(/capture \? \(begin.*captures\[1\]/m, program.source)
    assert program.search("aba", 0, capture: false)
  end

  def test_dead_capture_elimination_preserves_match_captures
    regexp = Onibi::Regexp.new("(a)(b)\\1")

    match = regexp.match("aba")

    assert_equal "a", match[1]
    assert_equal "b", match[2]
  end
end
