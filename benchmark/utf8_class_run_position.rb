# frozen_string_literal: true

require "benchmark/ips"
require_relative "../lib/onibi"

input = "#{"é" * 2048}abc!".freeze
position = 2048
run = Onibi::Experimental::Swar::ClassRun.new("a-z")
predicate = Onibi::ClassPredicates.compiled("a-z")

def legacy_character_search(input, position, predicate)
  cursor = position
  input.each_char.with_index do |character, index|
    next if index < position
    break unless predicate.matches?(character)

    cursor = index + 1
  end
  cursor == position ? false : [position, cursor, []]
end

Benchmark.ips do |x|
  x.config(time: 3, warmup: 1)
  x.report("legacy utf8 position") { legacy_character_search(input, position, predicate) }
  x.report("sliced utf8 position") { run.search(input, position, capture: true) }
  x.compare!
end
