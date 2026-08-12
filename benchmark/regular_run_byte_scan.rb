# frozen_string_literal: true

require "benchmark/ips"
require_relative "../lib/onibi"

input = ("abc123" * 128).freeze
predicates = %w[a-z 0-9].map { |source| Onibi::ClassPredicates.compiled(source) }
run = Onibi::Codegen::RegularRun.new(%w[a-z 0-9])

# rubocop:disable Metrics/BlockNesting
character_index_scan = lambda do
  cursor = 0
  while cursor < input.length
    if predicates[0].matches?(input[cursor])
      finish = cursor
      finish += 1 while finish < input.length && predicates[0].matches?(input[finish])
      if predicates[1].matches?(input[finish])
        finish += 1 while finish < input.length && predicates[1].matches?(input[finish])
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
  x.report("character-index regular scan", &character_index_scan)
  x.report("byte-table regular scan") { run.search(input, 0, capture: false) }
  x.compare!
end
