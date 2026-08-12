# frozen_string_literal: true

require "benchmark/ips"
require_relative "../lib/onibi"

source = "\\x80-\\xFF".b.freeze
input = (0..255).map { |byte| byte.chr(Encoding::ASCII_8BIT) }.join.freeze
predicate = Onibi::ClassPredicates.compiled(source)

Benchmark.ips do |x|
  x.config(time: 1, warmup: 0.5)
  x.report("source predicate loop") do
    input.each_char { |character| Onibi::ClassPredicates.match_source(source, character, false) }
  end
  x.report("compiled 256-byte table") do
    input.each_char { |character| predicate.matches?(character) }
  end
  x.compare!
end
