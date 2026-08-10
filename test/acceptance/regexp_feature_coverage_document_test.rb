# frozen_string_literal: true

require "test_helper"

class RegexpFeatureCoverageDocumentTest < Minitest::Test
  DOCUMENT_PATH = File.expand_path("../../docs/regexp-feature-coverage.md", __dir__)

  REQUIRED_SECTIONS = [
    "Ruby 4.0.6 の機能一覧",
    "Onibi のカバレッジ判定",
    "今後の実行タスク",
    "REGEXP-001"
  ].freeze

  def test_coverage_document_records_ruby_features_and_follow_up_tasks
    document = File.read(DOCUMENT_PATH)

    REQUIRED_SECTIONS.each { |section| assert_includes document, section }
    assert_includes document, "https://docs.ruby-lang.org/en/4.0/Regexp.html"
    assert_includes document, "https://docs.ruby-lang.org/en/4.0/MatchData.html"
    assert_includes document, "position 引数"
    assert_includes document, "compiled pattern の ignorecase"
    assert_includes document, "scoped multiline"
  end
end
