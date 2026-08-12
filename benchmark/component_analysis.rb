# frozen_string_literal: true

require "optparse"

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "onibi"

## Measures compile-time component analysis and matching fixture costs.
module ComponentAnalysisBenchmark
  CASES = {
    alternation: ["cat|dog|fox", "the quick fox"],
    prefix_suffix: ["\\Apre[a-z]fix\\z", "prelude-fix"],
    long_run: ["prefix[a-z]+suffix", "xprefix#{"a" * 200}suffix"]
  }.freeze
  OPERATIONS = %w[compile match].freeze

  def self.run(operation:, time:, warmup:)
    require "benchmark/ips"
    cases = CASES
    Benchmark.ips do |benchmark|
      benchmark.config(time: time, warmup: warmup)
      cases.each do |name, (pattern, input)|
        regexp = Onibi::Regexp.new(pattern) if operation == "match"
        benchmark.report("#{name}/#{operation}") do
          if operation == "compile"
            Onibi::Regexp.new(pattern)
          else
            regexp.match?(input)
          end
        end
      end
    end
  end

  def self.cli(arguments)
    options = { operation: "compile", time: 1.0, warmup: 0.5 }
    parser = OptionParser.new do |opts|
      opts.on("--operation NAME", OPERATIONS) { |value| options[:operation] = value }
      opts.on("--time SECONDS", Float) { |value| options[:time] = value }
      opts.on("--warmup SECONDS", Float) { |value| options[:warmup] = value }
    end
    parser.parse!(arguments)
    run(**options)
  end
end

ComponentAnalysisBenchmark.cli(ARGV) if $PROGRAM_NAME == __FILE__
