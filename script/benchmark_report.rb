# frozen_string_literal: true

require "benchmark/ips"
require "json"
require "optparse"
require "stringio"

ROOT = File.expand_path(ENV.fetch("ONIBI_ROOT", File.join(__dir__, "..")))
$LOAD_PATH.unshift File.join(ROOT, "lib")
$LOAD_PATH.unshift File.join(ROOT, "benchmark")
require "onibi"
require "regexp_features"
require "regex_redux"

module BenchmarkReport
  # Runs the checked-in benchmark corpus and returns machine-readable results.
  class Runner
    def initialize(time:, warmup:)
      @time = time
      @warmup = warmup
      @results = {}
    end

    def run
      run_feature_benchmarks
      run_regex_redux
      @results
    end

    private

    def run_feature_benchmarks
      RegexpFeatureBenchmark::Suite.load.cases.each do |benchmark_case|
        RegexpFeatureBenchmark::Runner::OPERATIONS.each do |operation|
          report("#{benchmark_case.label}/#{operation}") do |benchmark|
            benchmark.report("ruby") { feature_operation(benchmark_case, operation, Regexp) }
            benchmark.report("onibi") { feature_operation(benchmark_case, operation, Onibi::Regexp) }
          end
        end
      end
    end

    def feature_operation(benchmark_case, operation, engine)
      case operation
      when "compile"
        benchmark_case.compile(engine)
      when "first_match"
        benchmark_case.first_match(engine)
      when "match"
        regexp = engine == Regexp ? benchmark_case.ruby_regexp : benchmark_case.onibi_regexp
        regexp.match?(benchmark_case.input)
      end
    end

    def run_regex_redux
      input = File.read(File.join(ROOT, "benchmark", "fasta-500.txt"))
      %i[ruby onibi].each do |engine|
        report("regex-redux/500/#{engine}") do |benchmark|
          benchmark.report(engine.to_s) { RegexRedux.new(StringIO.new(input), engine: engine).to_s }
        end
      end
    end

    def report(name, &block)
      report = Benchmark.ips(time: @time, warmup: @warmup, quiet: true, &block)

      report.entries.each do |entry|
        @results["#{name}/#{entry.label}"] = {
          "ips" => entry.ips,
          "error" => entry.ips_sd
        }
      end
    end
  end

  # Renders a pair of benchmark result hashes as a pull request comment.
  class Markdown
    MARKER = "<!-- onibi-benchmark-report -->"

    def initialize(before, after)
      @before = before
      @after = after
    end

    def render
      rows = (@before.keys | @after.keys).sort.map { |name| row(name) }
      [MARKER, "## Benchmark comparison", "", description, "", header, *rows].join("\n")
    end

    private

    def description
      "Higher IPS is better. Speedup is calculated as `after / before`; benchmark noise is shown as ± error."
    end

    def header
      "| Benchmark | Before (i/s) | After (i/s) | Change |\n| --- | ---: | ---: | --- |"
    end

    def row(name)
      before = @before[name]
      after = @after[name]
      before_ips = before&.fetch("ips")
      after_ips = after&.fetch("ips")
      change = change_label(before_ips, after_ips)
      "| #{name} | #{format_result(before)} | #{format_result(after)} | #{change} |"
    end

    def format_result(result)
      return "—" unless result

      "#{format("%.2f", result.fetch("ips"))} (±#{format("%.1f", result.fetch("error"))}%)"
    end

    def change_label(before, after)
      return "new" unless before
      return "removed" unless after

      ratio = after / before
      return "—" if (ratio - 1.0).abs < 0.0001

      ratio >= 1 ? "#{format("%.2f", ratio)}x faster" : "#{format("%.2f", 1 / ratio)}x slower"
    end
  end

  # Detects meaningful slowdowns in Onibi results. Ruby entries remain
  # informational; only entries ending in /onibi are regression gates.
  class RegressionChecker
    def initialize(before, after, threshold: 0.10)
      @before = before
      @after = after
      @threshold = threshold
    end

    def regressions
      @before.filter_map do |name, before_result|
        next unless name.end_with?("/onibi")

        after_result = @after[name]
        next unless after_result

        ratio = after_result.fetch("ips") / before_result.fetch("ips")
        next unless ratio < (1.0 - @threshold)

        { name: name, before: before_result.fetch("ips"), after: after_result.fetch("ips"), ratio: ratio }
      end
    end

    def assert_clean!
      failures = regressions
      return if failures.empty?

      details = failures.map do |failure|
        format("%<name>s: %<ratio>.2fx (%<before>.2f -> %<after>.2f i/s)", **failure)
      end
      raise "benchmark regression exceeds #{@threshold * 100}%:\n#{details.join("\n")}"
    end
  end

  # Provides the benchmark and comparison command-line interfaces.
  class CLI
    def self.run(arguments)
      options = parse_options(arguments)
      if options[:compare]
        check_regressions(options)
        return render_comparison(options)
      end

      data = { "results" => Runner.new(time: options[:time], warmup: options[:warmup]).run }
      write(options[:output], JSON.pretty_generate(data))
    end

    def self.check_regressions(options)
      return unless options[:max_regression]

      before, after = load_comparison(options)
      RegressionChecker.new(before, after, threshold: options[:max_regression]).assert_clean!
    end

    def self.parse_options(arguments)
      options = { output: nil, time: 1.0, warmup: 0.5, compare: nil, markdown_output: nil, max_regression: nil }
      OptionParser.new do |parser|
        add_output_options(parser, options)
        add_comparison_options(parser, options)
        add_timing_options(parser, options)
      end.parse!(arguments)
      options
    end

    def self.add_output_options(parser, options)
      parser.on("--output PATH") { |value| options[:output] = value }
      parser.on("--markdown-output PATH") { |value| options[:markdown_output] = value }
    end

    def self.add_comparison_options(parser, options)
      parser.on("--compare BEFORE,AFTER") { |value| options[:compare] = value.split(",", 2) }
      parser.on("--max-regression FRACTION", Float) { |value| options[:max_regression] = value }
    end

    def self.add_timing_options(parser, options)
      parser.on("--time SECONDS", Float) { |value| options[:time] = value }
      parser.on("--warmup SECONDS", Float) { |value| options[:warmup] = value }
    end

    def self.render_comparison(options)
      before, after = load_comparison(options)
      write(options[:markdown_output], Markdown.new(before, after).render)
    end

    def self.load_comparison(options)
      options[:compare].map { |path| JSON.parse(File.read(path)).fetch("results") }
    end

    def self.write(path, content)
      path ? File.write(path, content) : puts(content)
    end
  end
end

BenchmarkReport::CLI.run(ARGV) if $PROGRAM_NAME == __FILE__
