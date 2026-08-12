# frozen_string_literal: true

require "optparse"

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "onibi"

# Measures scaling by input size, match location, failure mode, and public API.
module RegexpScalingProfiler
  CASES = {
    "literal_start" => ->(size) { ["needle", "needle#{"x" * size}"] },
    "literal_end" => ->(size) { ["needle", "#{"x" * size}needle"] },
    "literal_miss" => ->(size) { ["needle", "x" * size] },
    "anchored_miss" => ->(size) { ["\\Aneedle", "x" * size] },
    "dotstar_hit" => ->(size) { ["a.*z", "a#{"x" * size}z"] },
    "dotstar_miss" => ->(size) { ["a.*z", "a#{"x" * size}"] },
    "class_hit" => ->(size) { ["[a-z]+[0-9]+", "#{"x" * size}1"] },
    "class_miss" => ->(size) { ["[a-z]+[0-9]+", "x" * size] },
    "dense_literal" => ->(size) { ["a", "a" * size] }
  }.freeze
  OPERATIONS = %w[match_question match scan gsub].freeze
  HEADERS = %i[case engine operation input_size iterations seconds_per_iteration allocations_per_iteration
               gc_per_iteration].freeze

  # Adapts Ruby and Onibi to the same profiling operations.
  class Engine
    def initialize(name)
      @name = name
    end

    def compile(pattern)
      @name == "ruby" ? Regexp.new(pattern) : Onibi::Regexp.new(pattern)
    end

    def execute(regexp, input, operation)
      case operation
      when "match_question" then regexp.match?(input)
      when "match" then regexp.match(input)
      when "scan" then @name == "ruby" ? input.scan(regexp) : regexp.scan(input)
      when "gsub" then @name == "ruby" ? input.gsub(regexp, "_") : regexp.gsub(input, "_")
      end
    end
  end

  # Measures one case/operation/size matrix with correctness preflight.
  class Runner
    def initialize(options)
      @options = options
      @engine = Engine.new(options[:engine])
    end

    def run
      cases.product(operations, @options[:sizes]).map do |case_name, operation, size|
        measure(case_name, operation, size)
      end
    end

    private

    def cases
      @options[:case] == "all" ? CASES.keys : [@options[:case]]
    end

    def operations
      @options[:operation] == "all" ? OPERATIONS : [@options[:operation]]
    end

    def measure(case_name, operation, size)
      pattern, input = CASES.fetch(case_name).call(size)
      regexp = @engine.compile(pattern)
      verify!(pattern, input, operation, regexp)
      @engine.execute(regexp, input, operation) if @options[:engine] == "onibi"
      before = GC.stat
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @options[:iterations].times { @engine.execute(regexp, input, operation) }
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      build_row(case_name, operation, input, elapsed, before)
    end

    def verify!(pattern, input, operation, regexp)
      expected = normalize(Engine.new("ruby").execute(Regexp.new(pattern), input, operation))
      actual = normalize(@engine.execute(regexp, input, operation))
      raise "result mismatch for #{pattern.inspect} #{operation}" unless actual == expected
    end

    def normalize(value)
      return [value.begin(0), value.end(0), value.captures] if value.respond_to?(:captures)

      value
    end

    def build_row(case_name, operation, input, elapsed, before)
      iterations = @options[:iterations]
      {
        case: case_name, engine: @options[:engine], operation: operation, input_size: input.length,
        iterations: iterations, seconds_per_iteration: elapsed / iterations,
        allocations_per_iteration:
          (GC.stat[:total_allocated_objects] - before[:total_allocated_objects]).fdiv(iterations),
        gc_per_iteration: (GC.stat[:count] - before[:count]).fdiv(iterations)
      }
    end
  end

  # Emits scaling rows for humans or downstream analysis.
  class Reporter
    def self.print(rows, format)
      if format == "tsv"
        puts HEADERS.join("\t")
        rows.each { |row| puts HEADERS.map { |header| row.fetch(header) }.join("\t") }
      else
        puts "| #{HEADERS.join(" | ")} |"
        puts "|#{HEADERS.map { "---" }.join("|")}|"
        rows.each { |row| puts "| #{HEADERS.map { |header| row.fetch(header) }.join(" | ")} |" }
      end
    end
  end

  # Parses the scaling-profiler command line.
  class CLI
    def self.run(arguments)
      options = { engine: "onibi", case: "all", operation: "match_question",
                  sizes: [64, 1024, 16_384], iterations: 3, format: "markdown" }
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: ruby script/profile_regexp_scaling.rb [options]"
        opts.on("--engine NAME", %w[ruby onibi]) { |value| options[:engine] = value }
        opts.on("--case NAME", CASES.keys + ["all"]) { |value| options[:case] = value }
        opts.on("--operation NAME", OPERATIONS + ["all"]) { |value| options[:operation] = value }
        opts.on("--sizes LIST") { |value| options[:sizes] = value.split(",").map(&:to_i) }
        opts.on("--iterations N", Integer) { |value| options[:iterations] = value }
        opts.on("--format FORMAT", %w[markdown tsv]) { |value| options[:format] = value }
      end
      parser.parse!(arguments)
      Reporter.print(Runner.new(options).run, options[:format])
    rescue StandardError => e
      warn e.message
      warn parser
      exit 1
    end
  end
end

RegexpScalingProfiler::CLI.run(ARGV) if $PROGRAM_NAME == __FILE__
