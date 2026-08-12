# frozen_string_literal: true

require "benchmark/ips"
require_relative "../lib/onibi"

source = "a-z"
index = Onibi::ClassPredicates::TableRegistry.register(source)

Benchmark.ips do |x|
  x.config(time: 1, warmup: 0.5)
  x.report("compiled source lookup") { Onibi::ClassPredicates.compiled(source) }
  x.report("predicate table ID lookup") { Onibi::ClassPredicates::TableRegistry.fetch(index) }
  x.compare!
end
