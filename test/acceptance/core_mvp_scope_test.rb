# frozen_string_literal: true

require 'test_helper'
require_relative '../support/core_mvp_corpus'

class CoreMvpScopeTest < Minitest::Test
  REQUIRED_FIELDS = %i[id feature pattern options input expected].freeze

  def test_core_mvp_corpus_has_complete_cases
    refute_empty CoreMvpCorpus::CASES

    CoreMvpCorpus::CASES.each do |case_definition|
      assert_equal REQUIRED_FIELDS, (REQUIRED_FIELDS & case_definition.keys), case_definition[:id]
      assert case_definition.key?(:supported), case_definition[:id]
    end
  end

  def test_core_mvp_corpus_covers_required_supported_features
    required_features = %i[
      literal
      concatenation
      alternation
      capture
      quantifier
      character_class
      escape
      anchor
      option
      utf8
      ascii8bit
    ]

    covered_features = CoreMvpCorpus::CASES.filter_map do |case_definition|
      case_definition[:feature] if case_definition[:supported]
    end.uniq

    assert_equal required_features.sort, (required_features & covered_features).sort
  end

  def test_unsupported_features_are_explicitly_marked
    unsupported = CoreMvpCorpus::CASES.reject { |case_definition| case_definition[:supported] }

    refute_empty unsupported
    assert(unsupported.all? { |case_definition| case_definition[:expected] == :unsupported })
  end
end
