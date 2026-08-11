# frozen_string_literal: true

require "test_helper"
require "yaml"
require_relative "../../../fuzz/fuzzer"

class FuzzTest < Minitest::Test
  CORPUS_PATH = File.join(PROJECT_ROOT, "fuzz", "seed_corpus.yml")
  WORKFLOW_PATH = File.join(PROJECT_ROOT, ".github", "workflows", "scheduled-fuzz.yml")

  def test_fixed_seed_smoke_is_reproducible
    seed = YAML.safe_load(File.read(CORPUS_PATH)).fetch("seeds").first
    first = Fuzzer.run(seed: seed.fetch("seed"), cases: seed.fetch("cases"))
    second = Fuzzer.run(seed: seed.fetch("seed"), cases: seed.fetch("cases"))

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

    result = Fuzzer.run(seed: 20_260_811, cases: 8, onibi_class: mutant)

    assert_operator result.fetch(:mismatches), :>, 0
    assert_equal 20_260_811, result.fetch(:seed)
    assert(result.fetch(:failures).all? { |failure| failure.fetch(:seed) == 20_260_811 })
  end

  def test_failure_report_contains_reproduction_details
    report = Fuzzer.report(failure_result)

    assert_includes report, "Seed: `123`"
    assert_includes report, "Case 2"
    assert_includes report, "pattern: a+"
    assert_includes report, "mri: false"
    assert_includes report, "onibi: true"
    assert_includes report, "ONIBI_FUZZ_SEED=123"
  end

  def test_scheduled_workflow_runs_on_main_and_reports_failures
    workflow = File.read(WORKFLOW_PATH)

    assert_includes workflow, 'cron: "30 15 * * *"'
    assert_includes workflow, "ONIBI_FUZZ_SEED: ${{ github.run_id }}"
    assert_includes workflow, "issues: write"
    assert_includes workflow, "gh issue create --title \"$title\" --body-file fuzz-report.md"
  end

  def failure_result
    {
      seed: 123,
      cases: 4,
      mismatches: 1,
      failures: [{
        seed: 123,
        case: 2,
        fixture: { pattern: "a+", options: 0, input: "b", operation: :match? },
        mri: false,
        onibi: true
      }]
    }
  end
end
