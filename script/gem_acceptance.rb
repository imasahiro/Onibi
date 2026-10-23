# frozen_string_literal: true

FILTER_ENV = %w[N X A TESTOPTS FILTER MT_LIB_EXTRAS MT_NO_PLUGINS MT_HELL].freeze
EXCLUDED_TEST = "RegexpUtilityTest#test_last_match_matches_mri_and_match_question_does_not_change_it"
EXCLUDED_FILTER = "/\\A#{Regexp.escape(EXCLUDED_TEST)}\\z/"
TEST_GLOBS = ["test/**/test_*.rb", "test/**/*_test.rb"].freeze

filter_vars = FILTER_ENV.select { |name| ENV.key?(name) }
abort "gem acceptance rejects filter inputs: #{filter_vars.join(", ")}" unless filter_vars.empty?
abort "gem acceptance accepts no command-line arguments" unless ARGV.empty?

seed = ENV.fetch("SEED", "51748")
abort "SEED must contain only decimal digits" unless /\A[0-9]+\z/.match?(seed)
ENV["SEED"] = seed

test_files = TEST_GLOBS.flat_map { |glob| Dir.glob(glob) }.uniq.sort
abort "gem acceptance found no test files" if test_files.empty?

ARGV.replace(["--exclude", EXCLUDED_FILTER])
require "minitest/autorun"
Minitest.seed = seed.to_i % 0xFFFF

test_files.each { |path| require File.expand_path(path) }

test_ids = Minitest::Runnable.runnables.flat_map do |runnable|
  runnable.runnable_methods.map { |method| "#{runnable}##{method}" }
end

preflight_error =
  if test_ids.count(EXCLUDED_TEST) != 1
    "gem acceptance requires one test named #{EXCLUDED_TEST}"
  elsif test_ids.length < 2
    "gem acceptance requires tests outside #{EXCLUDED_TEST}"
  elsif ["--exclude", EXCLUDED_FILTER] != ARGV
    "a test file changed the gem acceptance arguments"
  end

if preflight_error
  warn preflight_error
  $stdout.flush
  exit! 1
end
