# frozen_string_literal: true

require "benchmark/ips"
require_relative "../lib/onibi"

input = "#{"\xFF" * 4096},tail".b.freeze
run = Onibi::Experimental::Swar::ClassRun.new("^,\\n")

Benchmark.ips do |x|
  x.config(time: 1, warmup: 0.5)
  x.report("ASCII-8BIT ClassRun") { run.search(input, 0, capture: false) }
  x.compare!
end
