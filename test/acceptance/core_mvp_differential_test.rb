# frozen_string_literal: true

require "test_helper"
require "yaml"
require_relative "../support/differential_harness"

class CoreMvpDifferentialTest < Minitest::Test
  CORPUS_PATH = File.expand_path("../../fixtures/core_mvp.yml", __dir__)

  def test_every_core_mvp_fixture_matches_mri
    corpus = YAML.safe_load(File.read(CORPUS_PATH))
    fixtures = corpus.fetch("cases").map { |fixture| normalize_fixture(fixture) }
    results = fixtures.map { |fixture| DifferentialHarness.compare(fixture) }

    assert_equal corpus.fetch("supported_features").sort, fixtures.map { |fixture| fixture.fetch(:feature, "") }.uniq.sort
    assert_equal fixtures.length, results.length
    assert results.all? { |result| result.fetch(:equal) }, mismatch_report(results)
  end

  private

  def normalize_fixture(fixture)
    encoding = Encoding.find(fixture.fetch("encoding"))
    {
      name: fixture.fetch("name"),
      feature: fixture.fetch("feature"),
      pattern: fixture.fetch("pattern").dup.force_encoding(encoding),
      options: fixture.fetch("options"),
      input: fixture.fetch("input").dup.force_encoding(encoding),
      operation: :match?
    }
  end

  def mismatch_report(results)
    results.reject { |result| result.fetch(:equal) }.map { |result| result.fetch(:message) }.join("\n")
  end
end
