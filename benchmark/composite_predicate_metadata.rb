# frozen_string_literal: true

require "benchmark/ips"
require_relative "../lib/onibi"

source = "a-z&&[^aeiou]"
predicate = Onibi::ClassPredicates.compiled(source)

Benchmark.ips do |x|
  x.config(time: 1, warmup: 0.5)
  x.report("source intersection parse") { Onibi::ClassPredicates.split_intersection(source) }
  x.report("normalized metadata lookup") { predicate.metadata.leaves }
  x.compare!
end
