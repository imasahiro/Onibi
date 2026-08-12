# frozen_string_literal: true

require "benchmark/ips"
require_relative "../lib/onibi"

input = "#{"abc123" * 128},".freeze
predicates = ["^,", ","].map { |source| Onibi::ClassPredicates.compiled(source) }
run = Onibi::Codegen::RegularRun.new(["^,", ","])

# rubocop:disable Metrics/BlockNesting
legacy_regular_run = lambda do
  cursor = 0
  while cursor < input.length
    if predicates[0].matches_byte?(input.getbyte(cursor))
      finish = cursor
      finish += 1 while finish < input.length && predicates[0].matches_byte?(input.getbyte(finish))
      if predicates[1].matches_byte?(input.getbyte(finish))
        finish += 1 while finish < input.length && predicates[1].matches_byte?(input.getbyte(finish))
        break
      end
      cursor = finish
    else
      cursor += 1
    end
  end
end
# rubocop:enable Metrics/BlockNesting

Benchmark.ips do |x|
  x.config(time: 1, warmup: 0.5)
  x.report("legacy byte scan", &legacy_regular_run)
  x.report("word-SWAR regular scan") { run.search(input, 0, capture: false) }
  x.compare!
end
