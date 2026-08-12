# frozen_string_literal: true

require "benchmark/ips"
require_relative "../lib/onibi"

keys = 128.times.map { |index| ["a-#{index % 26}", false].freeze }.freeze
target = keys.last
registry = Onibi::Codegen::PredicateRegistry.new
keys.each { |key| registry.register(key) }

Benchmark.ips do |x|
  x.config(time: 1, warmup: 0.5)
  x.report("array index lookup") { keys.index(target) }
  x.report("predicate registry lookup") { registry.register(target) }
  x.compare!
end
