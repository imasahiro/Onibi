# frozen_string_literal: true

require "bundler/gem_tasks"
require "minitest/test_task"

Minitest::TestTask.create

require "rubocop/rake_task"

RuboCop::RakeTask.new

task default: %i[test rubocop]

namespace :test do
  task :property do
    sh "ruby -Itest test/acceptance/v1_fuzz_test.rb"
  end

  task :fuzz do
    sh "ruby fuzz/run_v1_fuzz.rb"
  end
end
