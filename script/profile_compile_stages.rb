# frozen_string_literal: true

require "optparse"

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
$LOAD_PATH.unshift File.expand_path("../benchmark", __dir__)
require "onibi"
require "onibi/codegen"
require "regexp_features"

# Separates Onibi construction into front-end and generated-source stages.
module CompileStageProfiler
  HEADERS = %i[label stage iterations seconds_per_iteration allocations_per_iteration].freeze

  # Prepares reusable artifacts and isolated stage operations for one pattern.
  class CaseStages
    def initialize(benchmark_case)
      @case = benchmark_case
      @pattern = benchmark_case.pattern
      @options = benchmark_case.instance_variable_get(:@options)
      @tokens = Onibi::Lexer.new(@pattern, @options).tokens
      @ast = Onibi::Parser.new(@tokens).parse
      @source = Onibi::Codegen::RubyGenerator.ast(@ast, options: @options)
    end

    def operations
      {
        "lexer" => -> { Onibi::Lexer.new(@pattern, @options).tokens },
        "parser" => -> { Onibi::Parser.new(@tokens).parse },
        "analyzer" => -> { Onibi::Codegen::Analyzer.new(@options, @pattern.encoding).analyze(@ast) },
        "source_emit" => -> { Onibi::Codegen::RubyGenerator.ast(@ast, options: @options) },
        "source_compile" => -> { Onibi::Codegen::SourceCompiler.new.compile(@source) },
        "regexp_new" => -> { Onibi::Regexp.new(@pattern, options_mask) }
      }
    end

    private

    def options_mask
      @case.send(:options_mask)
    end
  end

  # Measures every compile stage for selected feature cases.
  class Runner
    def initialize(options)
      @options = options
      @cases = RegexpFeatureBenchmark::Suite.load.select(feature: options[:feature], encoding: options[:encoding])
    end

    def run
      raise ArgumentError, "no benchmark cases matched the filters" if @cases.empty?

      @cases.flat_map { |benchmark_case| measure_case(benchmark_case) }
    end

    private

    def measure_case(benchmark_case)
      CaseStages.new(benchmark_case).operations.map do |stage, operation|
        before = GC.stat[:total_allocated_objects]
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        @options[:iterations].times { operation.call }
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        {
          label: benchmark_case.label, stage: stage, iterations: @options[:iterations],
          seconds_per_iteration: elapsed / @options[:iterations],
          allocations_per_iteration: (GC.stat[:total_allocated_objects] - before).fdiv(@options[:iterations])
        }
      end
    end
  end

  # Emits compile-stage measurements.
  class Reporter
    def self.print(rows, format)
      separator = format == "tsv" ? "\t" : " | "
      puts HEADERS.join(separator)
      rows.each { |row| puts HEADERS.map { |header| row.fetch(header) }.join(separator) }
    end
  end

  # Parses compile-stage profiler options.
  class CLI
    def self.run(arguments)
      options = { iterations: 100, format: "markdown" }
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: ruby script/profile_compile_stages.rb [options]"
        opts.on("--feature NAME") { |value| options[:feature] = value }
        opts.on("--encoding NAME", %w[ascii utf8]) { |value| options[:encoding] = value }
        opts.on("--iterations N", Integer) { |value| options[:iterations] = value }
        opts.on("--format FORMAT", %w[markdown tsv]) { |value| options[:format] = value }
      end
      parser.parse!(arguments)
      Reporter.print(Runner.new(options).run, options[:format])
    rescue OptionParser::ParseError, ArgumentError => e
      warn e.message
      warn parser
      exit 1
    end
  end
end

CompileStageProfiler::CLI.run(ARGV) if $PROGRAM_NAME == __FILE__
