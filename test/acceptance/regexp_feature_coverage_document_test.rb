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
    assert_includes document, "`Regexp.new` の options ではなく regex literal"
    assert_includes document, "global match variables は設計スコープ外"
    assert_includes document, "public API inventory は MRI 4.0.6 の実装可能な全メソッドを比較"
    assert_includes document, "MatchData メソッド一覧を網羅"
    assert_includes document, "危険パターンの安全性を differential/property test"
    assert_includes document, "DFA memory budget"
    assert_includes document, "String/Symbol の match、match?、scan、gsub、sub 統合は v1 non-goal"
    assert_includes document, "ASCII-compatible pattern/input の全 4×4 encoding matrix"
    assert_includes document, "mode の on/off scope と comment/whitespace の parse/match を MRI と比較"
  end
end
