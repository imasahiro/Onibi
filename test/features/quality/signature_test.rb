# frozen_string_literal: true

require "test_helper"

class SignatureTest < Minitest::Test
  SIGNATURE_PATH = File.join(PROJECT_ROOT, "sig", "onibi.rbs")

  # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
  def test_signature_describes_the_public_api
    signature = File.read(SIGNATURE_PATH)

    assert_includes signature, "class Error < StandardError"
    assert_includes signature, "class RegexpError < Error"
    assert_includes signature, "class Regexp"
    assert_includes signature, "class TimeoutError < RegexpError"
    assert_includes signature, "NOENCODING: Integer"
    assert_includes signature, "def self.compile: (String pattern, ?Array[String]? options,"
    assert_includes signature, "?(String | Symbol | bool) options"
    assert_includes signature, "| (String pattern, ?Integer options, ?timeout: Numeric?) -> Regexp"
    assert_includes signature, "?timeout: Numeric?"
    assert_includes signature, "def initialize: (String pattern, ?Array[String]? options, ?timeout: Numeric?) -> void"
    assert_includes signature, "| (String pattern, ?Integer options, ?timeout: Numeric?) -> void"
    assert_includes signature, "def match?: (String input, ?Numeric position) -> bool"
    assert_includes signature, "def match: (String input, ?Numeric position) -> MatchData?"
    assert_includes signature, "def timeout: () -> Float?"
    assert_includes signature, "def encoding: () -> Encoding"
    assert_includes signature, "def fixed_encoding?: () -> bool"
    assert_includes signature, "(::Regexp pattern, ?timeout: Numeric?) -> Regexp"
    assert_includes signature, "(::Regexp pattern, ?timeout: Numeric?) -> void"
    assert_includes signature, "def options: () -> Integer"
    assert_includes signature, "def self.dfa_memory_budget: () -> Integer"
    assert_includes signature, "def self.dfa_memory_budget=: (Integer value) -> Integer"
    assert_includes signature, "def self.timeout: () -> Float?"
    assert_includes signature, "def self.timeout=: (Numeric? value) -> Float?"
    assert_includes signature, "def self.linear_time?:"
    assert_includes signature, "def self.union: (Array[String] patterns)"
    assert_includes signature, "def self.quote: (untyped string) -> String"
    assert_includes signature, "def self.try_convert: (untyped value) -> Regexp?"
    assert_includes signature, "def names: () -> Array[String]"
    assert_includes signature, "def named_captures: () -> Hash[String, Array[Integer]]"
    assert_includes signature, "def hash: () -> Integer\n    def to_s: () -> String\n    def inspect: () -> String"
    assert_includes signature, "class MatchData"
    assert_includes signature, "def []: (Integer index) -> String?"
    assert_includes signature, "def captures: () -> Array[String?]"
    assert_includes signature, "def offset: (Integer | String | Symbol index) -> [Integer, Integer]?"
    assert_includes signature, "def begin: (Integer | String | Symbol index) -> Integer?"
    assert_includes signature, "def end: (Integer | String | Symbol index) -> Integer?"
    assert_includes signature, "def to_a: () -> Array[String?]"
    assert_includes signature, "def length: () -> Integer"
    assert_includes signature, "def size: () -> Integer"
    assert_includes signature, "def named_captures: () -> Hash[String, String?]"
  end
  # rubocop:enable Metrics/AbcSize, Metrics/MethodLength
end
