# frozen_string_literal: true

require 'bundler/gem_tasks'
require 'rake/testtask'

Rake::TestTask.new(:test) do |t|
  t.libs << 'test'
  t.libs << 'lib'
  t.test_files = FileList['test/**/*_test.rb']
end

desc 'Run RuboCop'
task :rubocop do
  sh RbConfig.ruby, '-S', 'rubocop'
end

desc 'Build the gem'
Rake::Task[:build].clear

task build: :rubocop do
  sh RbConfig.ruby, '-S', 'gem', 'build', 'onibi.gemspec'
end

task default: :test
