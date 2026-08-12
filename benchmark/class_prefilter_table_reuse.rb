# frozen_string_literal: true

require "benchmark/ips"

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "onibi"

source = "a-z"
predicate = Onibi::ClassPredicates.compiled(source)

def legacy_class_prefilter_table(source)
  predicate = Onibi::ClassPredicates.compiled(source)
  Array.new(256) { |byte| predicate.matches?(byte.chr(Encoding::ASCII_8BIT)) }.freeze
end

prefilter = Onibi::Experimental::Swar::ClassPrefilter.new(source)
raise "table mismatch" unless prefilter.table.equal?(predicate.ascii_table)

Benchmark.ips do |benchmark|
  benchmark.config(time: 1, warmup: 0.5)
  benchmark.report("ClassPrefilter duplicate table (before)") { legacy_class_prefilter_table(source) }
  benchmark.report("reuse compiled ASCII table (after)") { Onibi::Experimental::Swar::ClassPrefilter.new(source) }
  benchmark.compare!
end
