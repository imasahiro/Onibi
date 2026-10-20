# frozen_string_literal: true

require "bundler/gem_tasks"
require "minitest/test_task"
require "rbconfig"

if Rake.application.top_level_tasks.include?("test:acceptance")
  filter_vars = %w[N X A TESTOPTS FILTER MT_LIB_EXTRAS MT_NO_PLUGINS MT_HELL].select { |name| ENV.key?(name) }
  abort "gem acceptance rejects filter inputs: #{filter_vars.join(", ")}" unless filter_vars.empty?
end

task :build_extension do
  Dir.chdir("ext/onibi") do
    sh RbConfig.ruby, "extconf.rb"
    sh "make"
  end
end

Minitest::TestTask.create
task test: :build_extension

task "test:acceptance" => :build_extension do
  sh RbConfig.ruby, "-Ilib:test:.", "-w", "script/gem_acceptance.rb"
end

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
