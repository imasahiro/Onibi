# frozen_string_literal: true

require "test_helper"

class SignatureTest < Minitest::Test
  SIGNATURE_PATH = File.expand_path("../../sig/onibi.rbs", __dir__)

  # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
  def test_signature_describes_the_public_api
    signature = File.read(SIGNATURE_PATH)

    assert_includes signature, "class Error < StandardError"
    assert_includes signature, "class RegexpError < Error"
    assert_includes signature, "class Regexp"
    assert_includes signature, "NOENCODING: Integer"
    assert_includes signature, "def self.compile: (String pattern) -> Regexp"
    assert_includes signature, "| (String pattern, Array[String]? options) -> Regexp"
    assert_includes signature, "| (String pattern, Integer options) -> Regexp"
    assert_includes signature, "def initialize: (String pattern) -> void"
    assert_includes signature, "| (String pattern, Array[String]? options) -> void"
    assert_includes signature, "| (String pattern, Integer options) -> void"
    assert_includes signature, "def match?: (String input) -> bool"
    assert_includes signature, "def match: (String input) -> MatchData?"
    assert_includes signature, "def options: () -> (Array[String] | Integer)"
    assert_includes signature, "def self.dfa_memory_budget: () -> Integer"
    assert_includes signature, "def self.dfa_memory_budget=: (Integer value) -> Integer"
    assert_includes signature, "class MatchData"
    assert_includes signature, "def []: (Integer index) -> String?"
    assert_includes signature, "def captures: () -> Array[String?]"
    assert_includes signature, "def offset: (Integer index) -> [Integer, Integer]?"
    assert_includes signature, "def begin: (Integer index) -> Integer?"
    assert_includes signature, "def end: (Integer index) -> Integer?"
    assert_includes signature, "def to_a: () -> Array[String?]"
    assert_includes signature, "def length: () -> Integer"
    assert_includes signature, "def size: () -> Integer"
    assert_includes signature, "def named_captures: () -> Hash[String, String?]"
  end
  # rubocop:enable Metrics/AbcSize, Metrics/MethodLength
end
