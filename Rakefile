# frozen_string_literal: true

require "bundler/gem_tasks"
require "minitest/test_task"
require "rbconfig"

task :build_extension do
  Dir.chdir("ext/onibi") do
    sh RbConfig.ruby, "extconf.rb"
    sh "make"
  end
end

Minitest::TestTask.create
task test: :build_extension

require "rubocop/rake_task"

RuboCop::RakeTask.new

task default: %i[test rubocop]

namespace :test do
  task :property do
    sh "ruby -Itest test/features/compatibility/fuzz_test.rb"
  end

  task :fuzz do
    sh "ruby fuzz/run.rb"
  end
end
