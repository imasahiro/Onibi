# frozen_string_literal: true

require "optparse"
require "yaml"

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "onibi"

# Data-driven feature microbenchmarks shared by Ruby Regexp and Onibi.
module RegexpFeatureBenchmark
  CASES_PATH = File.join(__dir__, "regexp_features.yml")
  ENCODINGS = { "ascii" => Encoding::US_ASCII, "utf8" => Encoding::UTF_8 }.freeze
  OPTIONS = { "ignorecase" => Regexp::IGNORECASE, "extended" => Regexp::EXTENDED,
              "multiline" => Regexp::MULTILINE }.freeze

  # One pattern/input pair measured with both engines.
  class Case
    attr_reader :feature, :name, :encoding, :pattern, :input

    def initialize(attributes)
      @feature = attributes.fetch("feature")
      @name = attributes.fetch("name")
      @encoding = attributes.fetch("encoding")
      @options = attributes.fetch("options", [])
      @pattern = encode(attributes.fetch("pattern"))
      @input = encode(attributes.fetch("input"))
    end

    def label
      "#{feature}/#{encoding}/#{name}"
    end

    def ruby_encoding
      ENCODINGS.fetch(encoding)
    end

    def ruby_regexp
      @ruby_regexp ||= Regexp.new(pattern, options_mask)
    end

    def onibi_regexp
      @onibi_regexp ||= Onibi::Regexp.new(pattern, options_mask)
    end

    def compile(engine)
      engine.new(pattern, options_mask)
    end

    def first_match(engine)
      compile(engine).match?(input)
    end

    private

    def encode(value)
      value.encode(ENCODINGS.fetch(encoding))
    end

    def options_mask
      @options.sum { |option| OPTIONS.fetch(option) }
    end
  end

  # Loads and filters the checked-in benchmark corpus.
  class Suite
    attr_reader :cases

    def self.load(path = CASES_PATH)
      rows = YAML.safe_load_file(path).fetch("cases")
      new(rows.map { |row| Case.new(row) })
    end

    def initialize(cases)
      @cases = cases
    end

    def select(feature: nil, encoding: nil)
      cases.select do |benchmark_case|
        (!feature || benchmark_case.feature == feature) &&
          (!encoding || benchmark_case.encoding == encoding)
      end
    end
  end

  # Runs pairwise IPS comparisons for selected cases and operations.
  class Runner
    OPERATIONS = %w[compile first_match match].freeze

    def initialize(suite:, options:)
      @cases = suite.select(feature: options[:feature], encoding: options[:encoding])
      @operations = options[:operation] == "all" ? OPERATIONS : [options[:operation]]
      @time = options[:time]
      @warmup = options[:warmup]
    end

    def run
      require "benchmark/ips"
      validate!
      @cases.each do |benchmark_case|
        @operations.each { |operation| run_case(benchmark_case, operation) }
      end
    end

    private

    def validate!
      raise ArgumentError, "no benchmark cases matched the filters" if @cases.empty?

      invalid = @operations - OPERATIONS
      raise ArgumentError, "unknown operation: #{invalid.first}" unless invalid.empty?
    end

    def run_case(benchmark_case, operation)
      puts "\n#{benchmark_case.label} [#{operation}]"
      Benchmark.ips do |benchmark|
        benchmark.config(time: @time, warmup: @warmup)
        add_reports(benchmark, benchmark_case, operation)
        benchmark.compare!
      end
    end

    def add_reports(benchmark, benchmark_case, operation)
      case operation
      when "compile"
        benchmark.report("ruby") { benchmark_case.compile(Regexp) }
        benchmark.report("onibi") { benchmark_case.compile(Onibi::Regexp) }
      when "first_match"
        benchmark.report("ruby") { benchmark_case.first_match(Regexp) }
        benchmark.report("onibi") { benchmark_case.first_match(Onibi::Regexp) }
      when "match"
        benchmark.report("ruby") { benchmark_case.ruby_regexp.match?(benchmark_case.input) }
        benchmark.report("onibi") { benchmark_case.onibi_regexp.match?(benchmark_case.input) }
      end
    end
  end

  # Parses the small command-line interface used by benchmark runs.
  class CLI
    def self.run(arguments)
      options = { operation: "match", time: 1.0, warmup: 0.5 }
      parser = option_parser(options)
      parser.parse!(arguments)
      suite = Suite.load
      return list(suite, options) if options.delete(:list)

      Runner.new(suite: suite, options: options).run
    end

    def self.option_parser(options)
      OptionParser.new.tap do |parser|
        parser.banner = "Usage: ruby benchmark/regexp_features.rb [options]"
        add_selection_options(parser, options)
        add_measurement_options(parser, options)
        parser.on("--list") { options[:list] = true }
      end
    end

    def self.add_selection_options(parser, options)
      parser.on("--feature NAME") { |value| options[:feature] = value }
      parser.on("--encoding NAME", %w[ascii utf8]) { |value| options[:encoding] = value }
      parser.on("--operation NAME", Runner::OPERATIONS + ["all"]) { |value| options[:operation] = value }
    end

    def self.add_measurement_options(parser, options)
      parser.on("--time SECONDS", Float) { |value| options[:time] = value }
      parser.on("--warmup SECONDS", Float) { |value| options[:warmup] = value }
    end

    def self.list(suite, options)
      suite.select(feature: options[:feature], encoding: options[:encoding]).each { |item| puts item.label }
    end
  end
end

RegexpFeatureBenchmark::CLI.run(ARGV) if $PROGRAM_NAME == __FILE__
