# frozen_string_literal: true

require_relative "../../test_helper"

class BacktrackCheckpointBenchmarkTest < Minitest::Test
  def test_capture_free_backtracking_fixture_matches_mri
    fixtures = {
      "a.*z" => %w[a-middle-z a-z a-middle],
      "a.+z" => %w[a-middle-z az a-middle],
      "a{1,4}z" => %w[aaaz az aaaaaz]
    }

    fixtures.each do |pattern, inputs|
      program = Onibi::Codegen::GeneratedProgram.ast(Onibi::Parser.new(pattern).parse, optimizations: [])
      inputs.each do |input|
        expected = ::Regexp.new(pattern).match?(input)
        actual = program.search(input, 0, capture: false)
        assert_equal expected, actual, [pattern, input]
      end
    end
  end
end
