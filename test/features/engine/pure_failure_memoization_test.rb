# frozen_string_literal: true

require_relative "../../test_helper"

class PureFailureMemoizationTest < Minitest::Test
  def test_search_source_contains_per_invocation_failure_memoization
    program = Onibi::Codegen::GeneratedProgram.ast(Onibi::Parser.new("a|b").parse)

    assert_includes program.optimization_passes, :pure_failure_memoization
    refute program.search("z", 0, capture: false)
  end

  def test_failure_memoization_preserves_capture_results
    regexp = Onibi::Regexp.new("(?<letter>a|b)\\k<letter>")

    assert regexp.match?("aa")
    assert regexp.match?("bb")
    refute regexp.match?("ab")
  end

  def test_pure_alternation_quantifier_gets_a_cursor_failure_cache
    program = Onibi::Codegen::GeneratedProgram.ast(Onibi::Parser.new("(?:a|b)*c").parse)

    assert_includes program.source, "failure_cache"
    assert program.search("ababc", 0, capture: false)
    refute program.search("ababd", 0, capture: false)
  end
end
