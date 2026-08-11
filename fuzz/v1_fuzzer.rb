# frozen_string_literal: true

require_relative "../lib/onibi"
require_relative "../test/support/differential_harness"
require "yaml"

## Generates small, reproducible MRI-vs-Onibi differential cases.
module V1Fuzzer
  PATTERNS = ["a", "a+", "ab", "(?<word>a+)", "a|b", "a?", "[ab]+", "."].freeze
  INPUTS = ["", "a", "A", "ab", "aaa", "bbb", "x"].freeze
  OPTIONS = [0, Onibi::Regexp::IGNORECASE].freeze

  module_function

  def run(seed:, cases:, onibi_class: Onibi::Regexp)
    random = Random.new(seed)
    failures = []

    cases.times do |index|
      fixture = fixture_for(random)
      mri = DifferentialHarness.execute(::Regexp, fixture)
      onibi = DifferentialHarness.execute(onibi_class, fixture)
      next if mri == onibi

      failures << { seed: seed, case: index, fixture: fixture, mri: mri, onibi: onibi }
    end

    { seed: seed, cases: cases, mismatches: failures.length, failures: failures }
  end

  def fixture_for(random)
    {
      pattern: PATTERNS.fetch(random.rand(PATTERNS.length)),
      options: OPTIONS.fetch(random.rand(OPTIONS.length)),
      input: INPUTS.fetch(random.rand(INPUTS.length)),
      operation: :match?
    }
  end

  def report(result)
    lines = report_header(result)

    result.fetch(:failures).each do |failure|
      lines.concat(report_failure(failure))
    end

    lines.join("\n")
  end

  def report_header(result)
    [
      "# Onibi fuzz report",
      "",
      "- Seed: `#{result.fetch(:seed)}`",
      "- Cases: `#{result.fetch(:cases)}`",
      "- Mismatches: `#{result.fetch(:mismatches)}`",
      "",
      "Re-run with:",
      "",
      "```sh",
      "ONIBI_FUZZ_SEED=#{result.fetch(:seed)} ONIBI_FUZZ_CASES=#{result.fetch(:cases)} ruby fuzz/run_v1_fuzz.rb",
      "```"
    ]
  end

  def report_failure(failure)
    [
      "",
      "## Case #{failure.fetch(:case)}",
      "",
      "```yaml",
      YAML.dump(failure),
      "```"
    ]
  end
end
