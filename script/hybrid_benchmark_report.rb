# frozen_string_literal: true

require "benchmark/ips"
require "json"
require "yaml"

ROOT = File.expand_path("..", __dir__)
$LOAD_PATH.unshift File.join(ROOT, "lib")
require "onibi"

OPTIONS = {
  "ignorecase" => Regexp::IGNORECASE,
  "multiline" => Regexp::MULTILINE,
  "extended" => Regexp::EXTENDED
}.freeze

def mri_options(options)
  options.sum { |option| OPTIONS.fetch(option, 0) }
end

def load_cases
  YAML.safe_load_file(File.join(ROOT, "benchmark", "regexp_features.yml")).fetch("cases")
end

def compile_hfa(pattern, options)
  Onibi::HybridAutomata.compile(pattern, options: options)
end

def compile_codegen(pattern, options)
  ast = Onibi::Parser.new(pattern, options).parse
  Onibi::Codegen::GeneratedProgram.ast(ast, options: options)
end

def build(engine, pattern, options)
  case engine
  when :hfa then compile_hfa(pattern, options)
  when :codegen then compile_codegen(pattern, options)
  when :mri then Regexp.new(pattern, mri_options(options))
  end
end

def match(engine, program, input)
  case engine
  when :hfa then program.match?(input)
  when :codegen then program.search(input, 0, capture: false) == true
  when :mri then program.match?(input)
  end
end

def ips(time, warmup, &block)
  report = Benchmark.ips(time: time, warmup: warmup, quiet: true) { |benchmark| benchmark.report(&block) }
  report.entries.first.ips
end

time = Float(ENV.fetch("ONIBI_HFA_BENCH_TIME", "0.1"))
warmup = Float(ENV.fetch("ONIBI_HFA_BENCH_WARMUP", "0.05"))
results = {}

load_cases.each do |fixture|
  pattern = fixture.fetch("pattern")
  input = fixture.fetch("input")
  options = fixture.fetch("options", [])
  label = "#{fixture.fetch("feature")}/#{fixture.fetch("encoding")}/#{fixture.fetch("name")}"
  expected = Regexp.new(pattern, mri_options(options)).match?(input)
  results[label] = {}

  %i[hfa codegen mri].each do |engine|
    compiled = build(engine, pattern, options)
    raise "semantic mismatch #{label}/#{engine}" unless match(engine, compiled, input) == expected

    results[label][engine] = {
      compile: ips(time, warmup) { build(engine, pattern, options) },
      first_match: ips(time, warmup) { match(engine, build(engine, pattern, options), input) },
      match: ips(time, warmup) { match(engine, compiled, input) }
    }
  end
end

puts JSON.pretty_generate("results" => results)
