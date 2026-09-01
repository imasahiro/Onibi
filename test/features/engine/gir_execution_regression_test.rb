# frozen_string_literal: true

require "test_helper"

class GirExecutionRegressionTest < Minitest::Test
  EXECUTOR_IDS = { regular: 0, tagged: 1, dynamic: 2 }.freeze
  EXECUTOR_KEYS = EXECUTOR_IDS.keys.freeze
  CASES = [
    ["definition-site subexpression", "(?i:(?<x>a))(?-i:\\g<x>)", "aA", :dynamic],
    ["failed match reset branch", "(?:a\\Kx|ab)", "ab", :tagged],
    ["successful match reset branch", "(?:a\\Kb|ab)", "ab", :tagged],
    ["UTF-8 lowercase property", "\\p{Lower}", "é", :regular],
    ["UTF-8 alphabetic property", "\\p{Alpha}", "あ", :regular],
    ["UTF-8 word property", "\\p{Word}", "あ", :regular],
    ["word boundary before ASCII", "\\Bx", "éx", :tagged],
    ["word boundary after ASCII", "x\\B", "xあ", :tagged],
    ["multibyte literal", "éx", "あéx", :regular],
    ["multibyte scan class", "[éあ]", "xéあy", :regular],
    ["nullable large repeat", "(a?){9}", "aaaa", :tagged],
    ["greedy capture priority", "(a*)(a*)", "aaa", :regular],
    ["lazy capture priority", "(a*?)(a*)", "aaa", :regular],
    ["converging counter paths", "(?:aa|a){9,10}b", "aaaaaaaaaab", :tagged],
    ["long anchored candidate", "\\Aa*\\z", "aaaa", :tagged]
  ].freeze

  def test_execution_strategy_matrix
    failures = []

    each_diagnostic do |name, expected_executor, info|
      failures << "#{name}: compiler did not publish RSeq" unless info[:rseq]
      failures << "#{name}: expected #{expected_executor}, got executor #{info[:exec_kind]}" unless info[:exec_kind] == EXECUTOR_IDS.fetch(expected_executor)
      failures << "#{name}: selected executor did not run" unless info.fetch(expected_executor).positive?

      (EXECUTOR_KEYS - [expected_executor]).each do |key|
        failures << "#{name}: unexpected #{key} executor" unless info.fetch(key).zero?
      end
      failures << "#{name}: selected executor used compatibility DFS" unless info[:dfs].zero?
    end

    assert_empty failures, failures.join("\n")
  end

  def test_native_completion_matrix_has_no_fallback
    failures = []

    each_diagnostic do |name, _expected_executor, info|
      failures << "#{name}: compiler did not publish RSeq" unless info[:rseq]
      failures << "#{name}: native execution returned status #{info[:status]}" unless info[:status] == 1
      failures << "#{name}: native execution entered MRI fallback" unless info[:fallback].zero?
    end

    assert_empty failures, failures.join("\n")
  end

  def test_diagnostic_match_positions_remain_byte_offsets
    info = Onibi::Regexp.new("éx").send(:__onibi_diagnostics__, "あéx")

    assert_equal 1, info[:status]
    assert_equal 3, info[:match_start]
    assert_equal 6, info[:match_end]
  end

  private

  def each_diagnostic
    CASES.each do |name, pattern, input, expected_executor|
      info = Onibi::Regexp.new(pattern).send(:__onibi_diagnostics__, input)
      yield name, expected_executor, info
    end
  end
end
