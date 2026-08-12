# frozen_string_literal: true

require "benchmark/ips"

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "onibi"

source = "a-z"
predicate = Onibi::ClassPredicates.compiled(source)
expected = predicate.ascii_table

def legacy_class_run_table(source)
  predicate = Onibi::ClassPredicates.compiled(source)
  Array.new(256) { |byte| predicate.matches?(byte.chr(Encoding::ASCII_8BIT)) }.freeze
end

run = Onibi::Experimental::Swar::ClassRun.new(source)
raise "table mismatch" unless run.table.equal?(expected)

Benchmark.ips do |benchmark|
  benchmark.config(time: 1, warmup: 0.5)
  benchmark.report("ClassRun duplicate table (before)") { legacy_class_run_table(source) }
  benchmark.report("reuse compiled ascii table (after)") { Onibi::Experimental::Swar::ClassRun.new(source) }
  benchmark.compare!
end
