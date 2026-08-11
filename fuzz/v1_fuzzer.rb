# frozen_string_literal: true

require_relative "../lib/onibi"
require_relative "../test/support/differential_harness"

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
end
