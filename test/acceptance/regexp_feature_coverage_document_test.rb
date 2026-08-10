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
    assert_includes document, "positive scoped extended mode / negative scoped extended mode"
    assert_includes document, "compiled pattern の multiline / extended scope"
    assert_includes document, "non-ASCII pattern の implicit FIXEDENCODING"
    assert_includes document, "Unicode property pattern の source encoding"
    assert_includes document, "negative scoped extended mode"
    assert_includes document, "scoped combined i/m/x modes"
    assert_includes document, "Ruby mode flag order"
    assert_includes document, "common control-character escapes"
    assert_includes document, "hex and Unicode escapes"
    assert_includes document, "character class escape decoder"
    assert_includes document, "caret control escapes"
  end
end
