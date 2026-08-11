# frozen_string_literal: true

require "test_helper"
require "yaml"
require_relative "../../fuzz/v1_fuzzer"

class V1FuzzTest < Minitest::Test
  CORPUS_PATH = File.expand_path("../../fuzz/v1_seed_corpus.yml", __dir__)

  def test_fixed_seed_smoke_is_reproducible
    seed = YAML.safe_load(File.read(CORPUS_PATH)).fetch("seeds").first
    first = V1Fuzzer.run(seed: seed.fetch("seed"), cases: seed.fetch("cases"))
    second = V1Fuzzer.run(seed: seed.fetch("seed"), cases: seed.fetch("cases"))

    assert_equal seed.fetch("cases"), first.fetch(:cases)
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
