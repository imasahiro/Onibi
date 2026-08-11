# frozen_string_literal: true

require "test_helper"
require "yaml"

class RuntimeContractTest < Minitest::Test
  RUNTIMES_PATH = File.join(PROJECT_ROOT, "docs", "v1-runtimes.yml")
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
    assert_equal observation_for(0), observation_for(1)
  end

  def test_specialization_modes_preserve_exception_results
    [0, 1].each { |budget| assert_type_error_for_budget(budget) }
  end

  private

  def observation_for(budget)
    with_budget(budget) do
      regexp = Onibi::Regexp.new("(?<word>a+)(?<suffix>b)?")
      3.times { regexp.match("xxaaab") }
      match = regexp.match("xxaaab")
      [match.to_a, match.offset(0), match.offset(1), match.offset(2), regexp.match?("xxaaab")]
    end
  end

  def assert_type_error_for_budget(budget)
    with_budget(budget) { assert_raises(TypeError) { Onibi::Regexp.new("a").match?(Object.new) } }
  end

  def with_budget(budget)
    original = Onibi::Regexp.dfa_memory_budget
    Onibi::Regexp.dfa_memory_budget = budget
    yield
  ensure
    Onibi::Regexp.dfa_memory_budget = original
  end
end
