# frozen_string_literal: true

require_relative "../lib/onibi"

PATTERNS = [
  "needle",
  "abc[0-9]+z",
  "a[bc]{4}z",
  "[a-z]+[0-9]+"
].freeze

def elapsed
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  yield
  Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
end

iterations = Integer(ENV.fetch("ONIBI_FRONTEND_ITERATIONS", 1_000))

puts "iterations=#{iterations}"
PATTERNS.each do |pattern|
  cold_cfg_time = elapsed do
    iterations.times do
      ast = Onibi::Parser.new(pattern).parse
      unit = Onibi::Codegen::Optimization.compile_prepared(ast, [], Encoding::US_ASCII)
      Onibi::HybridAutomata.compile_unit(unit)
    end
  end

  warm_cfg_time = elapsed do
    iterations.times do
      ast = Onibi::Parser.new(pattern).parse
      unit = Onibi::Codegen::Optimization.compile_prepared(ast, [], Encoding::US_ASCII)
      unit.cfg
      Onibi::HybridAutomata.compile_unit(unit)
    end
  end

  puts format("%<pattern>s cold_cfg=%<cold>.3fms warm_cfg=%<warm>.3fms",
              pattern: pattern, cold: cold_cfg_time * 1_000, warm: warm_cfg_time * 1_000)
end
