# frozen_string_literal: true

require "test_helper"
require "yaml"

class V1CrossRuntimeContractTest < Minitest::Test
  RUNTIMES_PATH = File.expand_path("../../docs/v1-runtimes.yml", __dir__)
  REQUIRED_RUNTIMES = %w[mri jruby truffleruby mruby].freeze

  def test_v1_runtime_matrix_pins_every_target
    runtimes = YAML.safe_load(File.read(RUNTIMES_PATH)).fetch("runtimes")

    assert_equal REQUIRED_RUNTIMES.sort, runtimes.map { |runtime| runtime.fetch("name") }.sort
    runtimes.each do |runtime|
      refute_empty runtime.fetch("version")
      refute_empty runtime.fetch("command")
    end
  end

  def test_specialization_modes_preserve_public_match_results
    source = "(?<word>a+)(?<suffix>b)?"
    input = "xxaaab"
    observations = [0, 1].map do |budget|
      original = Onibi::Regexp.dfa_memory_budget
      Onibi::Regexp.dfa_memory_budget = budget
      regexp = Onibi::Regexp.new(source)
      3.times { regexp.match(input) }
      match = regexp.match(input)
      [match.to_a, match.offset(0), match.offset(1), match.offset(2), regexp.match?(input)]
    ensure
      Onibi::Regexp.dfa_memory_budget = original
    end

    assert_equal observations.first, observations.last
  end

  def test_specialization_modes_preserve_exception_results
    [0, 1].each do |budget|
      original = Onibi::Regexp.dfa_memory_budget
      Onibi::Regexp.dfa_memory_budget = budget
      regexp = Onibi::Regexp.new("(?<word>a+)")

      assert_raises(TypeError) { regexp.match?(Object.new) }
    ensure
      Onibi::Regexp.dfa_memory_budget = original
    end
  end
end
