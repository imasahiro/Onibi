# frozen_string_literal: true

require "yaml"
require_relative "../../test_helper"

class HybridAutomataBenchmarkCoverageTest < Minitest::Test
  FIXTURE = File.join(PROJECT_ROOT, "benchmark", "regexp_features.yml")

  def test_hfa_covers_every_benchmark_fixture
    YAML.load_file(FIXTURE).fetch("cases").each do |fixture|
      program = Onibi::HybridAutomata.compile(fixture.fetch("pattern"),
                                              options: fixture.fetch("options", []))
      expected = ::Regexp.new(fixture.fetch("pattern"),
                              mri_options(fixture.fetch("options", []))).match?(fixture.fetch("input"))
      assert_equal expected, program.match?(fixture.fetch("input")), fixture.fetch("name")
    end
  end

  private

  def mri_options(options)
    options.sum do |option|
      { "ignorecase" => ::Regexp::IGNORECASE, "multiline" => ::Regexp::MULTILINE,
        "extended" => ::Regexp::EXTENDED }.fetch(option, 0)
    end
  end
end
