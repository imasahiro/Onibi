# frozen_string_literal: true

require_relative "../lib/onibi"

Case = Data.define(:name, :pattern, :input)
Adapter = Data.define(:name, :build)

SIZE = Integer(ENV.fetch("ONIBI_BENCH_SIZE", 262_144))
DURATION = Float(ENV.fetch("ONIBI_BENCH_TIME", "0.5"))
SAMPLES = Integer(ENV.fetch("ONIBI_BENCH_SAMPLES", 31))
ALLOCATIONS = Integer(ENV.fetch("ONIBI_BENCH_ALLOCATIONS", "0")) == 1
ALLOCATION_ITERATIONS = Integer(ENV.fetch("ONIBI_BENCH_ALLOCATION_ITERATIONS", 1_000))

CASES = [
  Case.new("literal_sparse_miss", "needle", "x" * SIZE),
  Case.new("prefix_sparse_late", "BEGIN(?:[a-z]+|[0-9]{2,4})END",
           "#{"x" * SIZE}BEGIN123END"),
  Case.new("prefix_dense_dfa", "BEGIN(?:ab|ac|ad|ba|bc|bd)+z",
           "#{"BEGINabacadbabcbdx" * [SIZE / 18, 1].max}BEGINabacadbabcbdz"),
  Case.new("dfa_dense_hit", "(?:ab|ac|ad|ba|bc|bd)+z",
           "#{"abacadbabcbd" * (SIZE / 12)}z"),
  Case.new("low_selectivity_miss", "a[bc]{4}z", "abcbx" * (SIZE / 5)),
  Case.new("static_sparse_late", "a[bc]{4}z",
           "#{"x" * [SIZE - 8, 0].max}a#{"x" * 7}")
].freeze
CASES_TO_RUN = CASES.select do |kase|
  filter = ENV["ONIBI_BENCH_CASE"]
  filter.nil? || kase.name == filter
end.freeze

ADAPTERS = [
  Adapter.new("hybrid", lambda do |pattern|
    program = Onibi::HybridAutomata.compile(pattern)
    ->(input) { program.match?(input) }
  end),
  Adapter.new("hybrid_ruby", lambda do |pattern|
    program = Onibi::HybridAutomata.compile(pattern).ruby_program
    ->(input) { program.match?(input) }
  end),
  Adapter.new("no_dfa", lambda do |pattern|
    program = Onibi::HybridAutomata.compile(pattern, dfa: false)
    ->(input) { program.match?(input) }
  end),
  Adapter.new("no_string", lambda do |pattern|
    program = Onibi::HybridAutomata.compile(pattern, string_matching: false)
    ->(input) { program.match?(input) }
  end),
  Adapter.new("nfa_only", lambda do |pattern|
    program = Onibi::HybridAutomata.compile(pattern, dfa: false, string_matching: false)
    ->(input) { program.match?(input) }
  end),
  Adapter.new("ruby_codegen", lambda do |pattern|
    ast = Onibi::Parser.new(pattern).parse
    program = Onibi::Codegen::GeneratedProgram.ast(ast)
    ->(input) { program.search(input, 0, capture: false) == true }
  end),
  Adapter.new("mri", lambda do |pattern|
    regexp = ::Regexp.new(pattern)
    ->(input) { regexp.match?(input) }
  end)
].freeze

def monotonic
  Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

def median(values)
  sorted = values.sort
  sorted[sorted.length / 2]
end

def compile_us(adapter, pattern)
  samples = Array.new(SAMPLES) do
    started = monotonic
    adapter.build.call(pattern)
    (monotonic - started) * 1_000_000
  end
  median(samples)
end

def first_scan_us(adapter, kase)
  samples = Array.new(SAMPLES) do
    matcher = adapter.build.call(kase.pattern)
    started = monotonic
    matcher.call(kase.input)
    (monotonic - started) * 1_000_000
  end
  median(samples)
end

def warm_ips(adapter, kase)
  matcher = adapter.build.call(kase.pattern)
  3.times { matcher.call(kase.input) }
  iterations = 0
  started = monotonic
  deadline = started + DURATION
  while monotonic < deadline
    matcher.call(kase.input)
    iterations += 1
  end
  iterations / (monotonic - started)
end

def allocations_per_call(adapter, kase)
  matcher = adapter.build.call(kase.pattern)
  GC.start
  before = GC.stat(:total_allocated_objects)
  ALLOCATION_ITERATIONS.times { matcher.call(kase.input) }
  (GC.stat(:total_allocated_objects) - before).fdiv(ALLOCATION_ITERATIONS)
end

puts "Ruby: #{RUBY_DESCRIPTION}"
puts "Input target: #{SIZE} bytes; warm sample: #{DURATION}s; lifecycle samples: #{SAMPLES}"
puts
puts "| case | engine | compile us | first scan us | warm scans/s | vs codegen |"
puts "|---|---:|---:|---:|---:|---:|"

CASES_TO_RUN.each do |kase|
  expected = ::Regexp.new(kase.pattern).match?(kase.input)
  rows = ADAPTERS.map do |adapter|
    matcher = adapter.build.call(kase.pattern)
    actual = matcher.call(kase.input)
    raise "semantic mismatch for #{kase.name}/#{adapter.name}" unless actual == expected

    [adapter.name, compile_us(adapter, kase.pattern), first_scan_us(adapter, kase), warm_ips(adapter, kase)]
  end
  codegen_ips = rows.assoc("ruby_codegen").last
  rows.each do |name, compile, first, ips|
    puts format("| %<case_name>s | %<engine>s | %<compile>.1f | %<first>.1f | %<ips>.1f | %<ratio>.2fx |",
                case_name: kase.name, engine: name, compile: compile, first: first,
                ips: ips, ratio: ips / codegen_ips)
  end
end

if ALLOCATIONS
  puts
  puts "Allocations per call (#{ALLOCATION_ITERATIONS} warm calls)"
  puts "| case | engine | objects/call |"
  puts "|---|---:|---:|"
  CASES_TO_RUN.each do |kase|
    ADAPTERS.each do |adapter|
      puts format("| %<case>s | %<engine>s | %<objects>.1f |",
                  case: kase.name, engine: adapter.name,
                  objects: allocations_per_call(adapter, kase))
    end
  end
end
