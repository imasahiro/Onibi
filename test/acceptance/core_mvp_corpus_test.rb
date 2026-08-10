# frozen_string_literal: true

require "test_helper"
require "yaml"

class CoreMvpCorpusTest < Minitest::Test
  CORPUS_PATH = File.expand_path("../../fixtures/core_mvp.yml", __dir__)

  SUPPORTED_FEATURES = %w[
    anchors
    captures
    character_classes
    concatenation
    escapes
    literals
    options
    quantifiers
    unicode
  ].freeze

  def test_corpus_cases_have_a_complete_shape
    corpus = YAML.safe_load(File.read(CORPUS_PATH))

    assert_equal SUPPORTED_FEATURES.sort, corpus.fetch("supported_features").sort
    assert_no_supported_unsupported_overlap(corpus)
    corpus.fetch("cases").each { |fixture| assert_case_shape(fixture) }
  end

  def test_unsupported_features_are_explicitly_recorded
    corpus = YAML.safe_load(File.read(CORPUS_PATH))

    assert_equal %w[
      backreferences
      atomic_groups
      lookarounds
      named_captures
      possessive_quantifiers
      unicode_properties
    ].sort, corpus.fetch("unsupported_features").sort
  end

  private

  def assert_no_supported_unsupported_overlap(corpus)
    unsupported = corpus.fetch("unsupported_features")

    assert (unsupported & SUPPORTED_FEATURES).empty?
  end

  def assert_case_shape(fixture)
    required_keys = %w[encoding feature input name options outcome pattern]

    assert_equal required_keys.sort, fixture.keys.sort
    assert SUPPORTED_FEATURES.include?(fixture.fetch("feature")), fixture.fetch("feature")
    assert fixture.fetch("input").is_a?(String)
    assert fixture.fetch("name").is_a?(String)
    assert fixture.fetch("options").is_a?(Array)
    assert %w[ASCII-8BIT UTF-8].include?(fixture.fetch("encoding"))
    assert %w[match no_match error].include?(fixture.fetch("outcome"))
    assert fixture.fetch("pattern").is_a?(String)
  end
end
