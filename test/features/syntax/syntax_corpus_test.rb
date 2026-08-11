# frozen_string_literal: true

require "test_helper"
require "yaml"

class SyntaxCorpusTest < Minitest::Test
  CORPUS = :syntax

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

  TYPED_FIELDS = {
    "input" => String,
    "name" => String,
    "options" => Array,
    "pattern" => String
  }.freeze

  def test_corpus_cases_have_a_complete_shape
    corpus = TestFixtures.load(CORPUS)

    assert_equal SUPPORTED_FEATURES.sort, corpus.fetch("supported_features").sort
    assert_no_supported_unsupported_overlap(corpus)
    corpus.fetch("cases").each { |fixture| assert_case_shape(fixture) }
  end

  def test_unsupported_features_are_explicitly_recorded
    corpus = TestFixtures.load(CORPUS)

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
    assert_supported_feature(fixture)
    TYPED_FIELDS.each { |field, type| assert_kind_of type, fixture.fetch(field) }
    assert_includes %w[ASCII-8BIT UTF-8], fixture.fetch("encoding")
    assert_includes %w[match no_match error], fixture.fetch("outcome")
  end

  def assert_supported_feature(fixture)
    feature = fixture.fetch("feature")

    assert_includes SUPPORTED_FEATURES, feature
  end
end
