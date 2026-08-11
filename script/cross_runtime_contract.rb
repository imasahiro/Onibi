# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "onibi"

def assert_equal(expected, actual, label)
  return if expected == actual

  abort "#{label}: expected #{expected.inspect}, got #{actual.inspect}"
end

def with_budget(budget)
  original = Onibi::Regexp.dfa_memory_budget
  Onibi::Regexp.dfa_memory_budget = budget
  yield
ensure
  Onibi::Regexp.dfa_memory_budget = original
end

def observation_for(budget)
  with_budget(budget) do
    regexp = Onibi::Regexp.new("(?<word>a+)(?<suffix>b)?")
    3.times { regexp.match("xxaaab") }
    match = regexp.match("xxaaab")
    [match.to_a, match.offset(0), match.offset(1), match.offset(2), regexp.match?("xxaaab")]
  end
end

assert_equal observation_for(0), observation_for(1), "specialization results"
with_budget(0) { abort "exception contract" unless Onibi::Regexp.new("a").match?("a") }
with_budget(1) { abort "exception contract" unless Onibi::Regexp.new("a").match?("a") }
