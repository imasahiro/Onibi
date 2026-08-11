# frozen_string_literal: true

require "test_helper"

class RegexpFeatureCoverageDocumentTest < Minitest::Test
  DOCUMENT_PATH = File.join(PROJECT_ROOT, "docs", "regexp-feature-coverage.md")

  REQUIRED_SECTIONS = [
    "Ruby 4.0.6 の機能一覧",
    "Onibi のカバレッジ判定",
    "今後の実行タスク",
    "REGEXP-001"
  ].freeze
  REQUIRED_CONTENT = [
    "https://docs.ruby-lang.org/en/4.0/Regexp.html",
    "https://docs.ruby-lang.org/en/4.0/MatchData.html",
    "position 引数",
    "compiled pattern の ignorecase",
    "scoped multiline",
    "positive scoped extended mode / negative scoped extended mode",
    "compiled pattern の multiline / extended scope",
    "non-ASCII pattern の implicit FIXEDENCODING",
    "Unicode property pattern の source encoding",
    "negative scoped extended mode",
    "scoped combined i/m/x modes",
    "Ruby mode flag order",
    "common control-character escapes",
    "hex and Unicode escapes",
    "character class escape decoder",
    "caret control escapes",
    "`Regexp.new` の options ではなく regex literal",
    "global match variables は設計スコープ外",
    "public API inventory は MRI 4.0.6 の実装可能な全メソッドを比較",
    "MatchData メソッド一覧を網羅",
    "危険パターンの安全性を differential/property test",
    "generated Ruby source size と explicit backtrack/call/capture-trail budget",
    "String/Symbol の match、match?、scan、gsub、sub 統合は v1 non-goal",
    "ASCII-compatible pattern/input の全 4×4 encoding matrix",
    "mode の on/off scope と comment/whitespace の parse/match を MRI と比較",
    "constructor options の boolean/string/symbol flags",
    "`Regexp.union` の単一 Array 入力",
    "character class の acceptance corpus を MRI と比較",
    "Unicode/POSIX property の acceptance corpus を MRI と比較",
    "counting range suffix（`{min,max}+`）を受理し、MRI の greedy 相当 semantics と比較",
    "advanced syntax の acceptance corpus を MRI と比較",
    "### REGEXP-008 [Complete]",
    "全 encoding semantics のうち v1 で検証する範囲",
    "### REGEXP-010 [Complete]",
    "`Regexp.last_match` は global match state を導入しない v1 non-goal",
    "### REGEXP-011 [Complete]",
    "timeout/resource control の v1 scope",
    "### REGEXP-012 [Complete]",
    "MatchData integration の v1 scope"
  ].freeze

  def test_coverage_document_records_ruby_features_and_follow_up_tasks
    document = File.read(DOCUMENT_PATH)

    (REQUIRED_SECTIONS + REQUIRED_CONTENT).each { |content| assert_includes document, content }
  end

  def test_coverage_document_records_scan_gsub_scope
    document = File.read(DOCUMENT_PATH)

    assert_includes document, "### REGEXP-013 [Complete]"
    assert_includes document, "Onibi::Regexp#scan / #gsub"
  end
end
