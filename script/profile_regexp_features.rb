# frozen_string_literal: true

require "optparse"

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
$LOAD_PATH.unshift File.expand_path("../benchmark", __dir__)
require "onibi"
require "regexp_features"

# Per-case GC, allocation, generated-source, and YARV measurements for the
# feature microbenchmark corpus.
module RegexpFeatureProfiler
  OPERATIONS = RegexpFeatureBenchmark::Runner::OPERATIONS
  DEFAULTS = { engine: "onibi", operation: "all", iterations: 10, format: "markdown", yjit: false }.freeze

  # Measures each feature case while preserving cold and warm boundaries.
  class Runner
    def initialize(options)
      @options = options
      @suite = RegexpFeatureBenchmark::Suite.load
      @cases = @suite.select(feature: options[:feature], encoding: options[:encoding])
    end

    def run
      raise ArgumentError, "no benchmark cases matched the filters" if @cases.empty?

      enable_yjit if @options[:yjit]
      operations.map { |operation| @cases.map { |benchmark_case| measure(benchmark_case, operation) } }.flatten
    end

    private

    def operations
      @options[:operation] == "all" ? OPERATIONS : [@options[:operation]]
    end

    def measure(benchmark_case, operation)
      regexp = reusable_regexp(benchmark_case) if operation == "match"
      prime(regexp, benchmark_case.input) if regexp
      gc_before = GC.stat
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @options[:iterations].times do
        case operation
        when "compile" then benchmark_case.compile(engine_class)
        when "first_match" then benchmark_case.first_match(engine_class)
        when "match" then regexp.match?(benchmark_case.input)
        end
      end
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
      report(benchmark_case, operation, elapsed, gc_before, regexp)
    end

    def prime(regexp, input)
      regexp.match?(input) if regexp.is_a?(Onibi::Regexp)
    end

    def engine_class
      @options[:engine] == "ruby" ? Regexp : Onibi::Regexp
    end

    def reusable_regexp(benchmark_case)
      @options[:engine] == "ruby" ? benchmark_case.ruby_regexp : benchmark_case.onibi_regexp
    end

    def report(benchmark_case, operation, elapsed, gc_before, regexp)
      representative = regexp || (operation == "first_match" ? benchmark_case.compile(engine_class) : nil)
      generated = yarv_report(representative)
      {
        label: benchmark_case.label,
        operation: operation,
        iterations: @options[:iterations],
        seconds: elapsed,
        seconds_per_iteration: elapsed / @options[:iterations],
        allocations: GC.stat[:total_allocated_objects] - gc_before[:total_allocated_objects],
        gc_count: GC.stat[:count] - gc_before[:count],
        generated_source_bytes: generated[:source_bytes],
        yarv_instructions: generated[:instructions]
      }
    end

    def yarv_report(regexp)
      return { source_bytes: 0, instructions: 0 } unless regexp.is_a?(Onibi::Regexp)

      program = regexp.send(:codegen_program)
      iseq = RubyVM::InstructionSequence.of(program.compiled_module.method(:__onibi_search))
      {
        source_bytes: program.source.bytesize,
        instructions: iseq ? iseq.to_a.fetch(13).count { |entry| entry.is_a?(Array) } : 0
      }
    rescue StandardError
      { source_bytes: 0, instructions: 0 }
    end

    def enable_yjit
      RubyVM::YJIT.enable if defined?(RubyVM::YJIT) && RubyVM::YJIT.respond_to?(:enable)
    end
  end

  # Emits case measurements as Markdown or machine-readable TSV.
  class Reporter
    HEADERS = %i[
      label operation iterations seconds seconds_per_iteration allocations gc_count
      generated_source_bytes yarv_instructions
    ].freeze

    def initialize(rows, format)
      @rows = rows
      @format = format
    end

    def print
      @format == "tsv" ? print_tsv : print_markdown
    end

    private

    def print_tsv
      puts HEADERS.join("\t")
      @rows.each { |row| puts HEADERS.map { |header| row.fetch(header) }.join("\t") }
    end

    def print_markdown
      puts "| #{HEADERS.join(" | ")} |"
      puts "|#{HEADERS.map { |_| "---" }.join("|")}|"
      @rows.each do |row|
        puts "| #{HEADERS.map { |header| row.fetch(header) }.join(" | ")} |"
      end
    end
  end

  # Parses feature-profiler command-line options.
  class CLI
    def self.run(arguments)
      options = DEFAULTS.dup
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: ruby script/profile_regexp_features.rb [options]"
        opts.on("--engine NAME", %w[ruby onibi]) { |value| options[:engine] = value }
        opts.on("--operation NAME", OPERATIONS + ["all"]) { |value| options[:operation] = value }
        opts.on("--iterations N", Integer) { |value| options[:iterations] = value }
        opts.on("--feature NAME") { |value| options[:feature] = value }
        opts.on("--encoding NAME", %w[ascii utf8]) { |value| options[:encoding] = value }
        opts.on("--format FORMAT", %w[markdown tsv]) { |value| options[:format] = value }
        opts.on("--yjit") { options[:yjit] = true }
      end
      parser.parse!(arguments)
      raise ArgumentError, "iterations must be positive" unless options[:iterations].positive?

      Reporter.new(Runner.new(options).run, options[:format]).print
    rescue OptionParser::ParseError, ArgumentError => e
      warn e.message
      warn parser
      exit 1
    end
  end
end

RegexpFeatureProfiler::CLI.run(ARGV) if $PROGRAM_NAME == __FILE__
