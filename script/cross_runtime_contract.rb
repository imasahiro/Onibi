# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "onibi"

def assert_equal(expected, actual, label)
  return if expected == actual

  abort "#{label}: expected #{expected.inspect}, got #{actual.inspect}"
end

def observation
  regexp = Onibi::Regexp.new("(?<word>a+)(?<suffix>b)?")
  3.times { regexp.match("xxaaab") }
  match = regexp.match("xxaaab")
  [match.to_a, match.offset(0), match.offset(1), match.offset(2), regexp.match?("xxaaab")]
end

assert_equal [["aaab", "aaa", "b"], [2, 6], [2, 5], [5, 6], true], observation,
             "generated matcher results"
abort "exception contract" unless Onibi::Regexp.new("a").match?("a")
