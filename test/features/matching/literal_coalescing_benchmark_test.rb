# frozen_string_literal: true

require_relative "../../test_helper"

class LiteralCoalescingBenchmarkTest < Minitest::Test
  def test_coalesced_literal_run_matches_mri # rubocop:disable Metrics/AbcSize
    pattern = "abcdefgh"
    input = ("x" * 12 + pattern).freeze
    program = Onibi::Codegen::GeneratedProgram.ast(Onibi::Parser.new(pattern).parse, optimizations: [])

    assert_equal ::Regexp.new(pattern).match?(input), program.search(input, 0, capture: false)
    assert_equal [1, 0],
                 [program.source.scan("input[position, 8]").length, program.source.scan("input[cursor_1").length]
  end
end
