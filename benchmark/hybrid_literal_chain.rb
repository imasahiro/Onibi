# frozen_string_literal: true

require "optparse"

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "onibi"

# Compares the bounded-literal event coordinator with the previous literal-only search plan.
module HybridLiteralChainBenchmark
  CASES = {
    sparse_miss: ["foo.{0,64}bar", "foo-" * 512],
    sparse_late_hit: ["foo.{0,64}bar", ("foo-" * 512) + "foo#{"x" * 32}bar"],
    dense_class_miss: ["foo[a-z]{0,64}bar", "fooa" * 512]
  }.transform_values { |pattern, input| [pattern.freeze, input.freeze].freeze }.freeze
  OPERATIONS = %w[compile first_match match_question match scan gsub].freeze

  module_function

  def programs(pattern)
    ast = Onibi::Parser.new(pattern).parse
    hybrid = Onibi::Codegen::GeneratedProgram.ast(ast)
    baseline_plan = Onibi::Codegen::SearchPlan.new(
      **hybrid.search_plan.to_h.merge(candidate_source: nil)
    )
    baseline = Onibi::Codegen::GeneratedProgram.new(hybrid.source, search_plan: baseline_plan)
    [baseline, hybrid]
  end

  def run(operation:, time:, warmup:)
    require "benchmark/ips"

    Benchmark.ips do |benchmark|
      benchmark.config(time: time, warmup: warmup)
      CASES.each do |name, (pattern, input)|
        report_case(benchmark, name, pattern, input, operation)
      end
      benchmark.compare!
    end
  end

  def report_case(benchmark, name, pattern, input, operation)
    if operation == "match_question"
      baseline, hybrid = programs(pattern)
      benchmark.report("#{name}/baseline") { baseline.search(input, 0, capture: false) }
      benchmark.report("#{name}/hybrid") { hybrid.search(input, 0, capture: false) }
    end

    onibi = Onibi::Regexp.new(pattern)
    mri = Regexp.new(pattern)
    benchmark.report("#{name}/onibi/#{operation}") { execute(Onibi::Regexp, onibi, pattern, input, operation) }
    benchmark.report("#{name}/mri/#{operation}") { execute(Regexp, mri, pattern, input, operation) }
  end

  def execute(regexp_class, regexp, pattern, input, operation)
    case operation
    when "compile" then regexp_class.new(pattern)
    when "first_match" then regexp_class.new(pattern).match?(input)
    when "match_question" then regexp.match?(input)
    when "match" then regexp.match(input)
    when "scan" then regexp_class == Regexp ? input.scan(regexp) : regexp.scan(input)
    when "gsub" then regexp_class == Regexp ? input.gsub(regexp, "replacement") : regexp.gsub(input, "replacement")
    end
  end

  def cli(arguments)
    options = { operation: "match_question", time: 1.0, warmup: 0.5 }
    parser = OptionParser.new do |opts|
      opts.on("--operation NAME", OPERATIONS) { |value| options[:operation] = value }
      opts.on("--time SECONDS", Float) { |value| options[:time] = value }
      opts.on("--warmup SECONDS", Float) { |value| options[:warmup] = value }
    end
    parser.parse!(arguments)
    run(**options)
  end
end

HybridLiteralChainBenchmark.cli(ARGV) if $PROGRAM_NAME == __FILE__
