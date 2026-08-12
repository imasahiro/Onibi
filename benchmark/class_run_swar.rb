# frozen_string_literal: true

require "benchmark/ips"
require_relative "../lib/onibi"

input = ("abcxyz123" * 64).freeze
run = Onibi::Experimental::Swar::ClassRun.new("a-z")
predicate = Onibi::ClassPredicates.compiled("a-z")
negated_input = "#{"a" * 64},tail".freeze
negated_run = Onibi::Experimental::Swar::ClassRun.new("^,")
negated_predicate = Onibi::ClassPredicates.compiled("^,")

def legacy_class_run(input, predicate)
  cursor = legacy_word_scan(input, predicate)
  legacy_tail_scan(input, predicate.ascii_table, cursor)
end

def legacy_word_scan(input, predicate)
  cursor = 0
  word_bytes = Onibi::Experimental::Swar::ClassRun::WORD_BYTES
  table = predicate.ascii_table
  while cursor + word_bytes <= input.bytesize
    mask = 0
    cursor.upto(cursor + word_bytes - 1) do |index|
      mask |= 1 << (index - cursor) if table[input.getbyte(index)]
    end
    break unless mask == (1 << word_bytes) - 1

    cursor += word_bytes
  end
  cursor
end

def legacy_tail_scan(input, table, cursor)
  cursor += 1 while cursor < input.bytesize && table[input.getbyte(cursor)]
  cursor
end

def legacy_search(input, predicate, run)
  cursor = run.profitable?(input, 0) ? legacy_class_run(input, predicate) : 0
  cursor += 1 while cursor < input.bytesize && predicate.ascii_table[input.getbyte(cursor)]
  cursor.zero? ? false : true
end

Benchmark.ips do |x|
  x.config(time: 1, warmup: 0.5)
  x.report("baseline class loop") do
    cursor = 0
    cursor += 1 while cursor < input.length && predicate.matches?(input[cursor])
  end
  x.report("class run SWAR (before)") { legacy_search(input, predicate, run) }
  x.report("class run SWAR (after)") { run.search(input, 0, capture: false) }
  x.report("negated class run (before)") { legacy_class_run(negated_input, negated_predicate) }
  x.report("negated class run (after)") { negated_run.scan_end(negated_input, 0) }
  x.compare!
end
