# frozen_string_literal: true

require "test_helper"
require_relative "../../fuzz/v1_fuzzer"

class V1FuzzTest < Minitest::Test
  def test_fixed_seed_smoke_is_reproducible
    first = V1Fuzzer.run(seed: 20260811, cases: 32)
    second = V1Fuzzer.run(seed: 20260811, cases: 32)

    assert_equal 32, first.fetch(:cases)
    assert_equal 0, first.fetch(:mismatches)
    assert_equal first, second
  end

  def test_intentional_mutant_reports_seeded_differential_failure
    mutant = Class.new(Onibi::Regexp) do
      def match?(_input, _position = 0)
        false
      end
    end

    result = V1Fuzzer.run(seed: 20260811, cases: 8, onibi_class: mutant)

    assert_operator result.fetch(:mismatches), :>, 0
    assert_equal 20260811, result.fetch(:seed)
    assert result.fetch(:failures).all? { |failure| failure.fetch(:seed) == 20260811 }
  end
end
