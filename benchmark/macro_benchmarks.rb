# frozen_string_literal: true

require "optparse"

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "onibi"

# Reproducible, application-shaped extraction workloads for Ruby Regexp and
# Onibi::Regexp. The generated data is intentionally small enough for local
# correctness checks and scalable enough for warm macro measurements.
module MacroBenchmarks
  # Generates deterministic records shared by correctness and timing runs.
  class Corpus
    attr_reader :records

    def initialize(seed: 2026, records: 1_000)
      random = Random.new(seed)
      @records = Array.new(records) { |index| build_record(random, index) }
    end

    def input(name)
      records.map { |record| record.fetch(name.to_sym) }.join("\n")
    end

    def to_h
      records
    end

    private

    def build_record(random, index)
      values = request_values(random, index)

      access_record(values, index).merge(
        email: email_record(index),
        url: url_record(index),
        structured_log: structured_record(values, index),
        identifier: identifier_record(index)
      )
    end

    def request_values(random, index)
      {
        ip: index.even? ? "192.0.2.#{(index % 240) + 1}" : "2001:db8::#{index + 1}",
        method: %w[GET POST PUT].fetch(index % 3),
        uri: "/api/v#{(index % 3) + 1}/users/#{index}?page=#{(index % 5) + 1}&active=true",
        status: [200, 201, 404, 500].fetch(index % 4),
        bytes: 128 + random.rand(20_000)
      }
    end

    def access_record(values, index)
      {
        access_log: format(
          "%<ip>s - - [10/Aug/2026:12:00:%<second>02d +0000] " \
          "\"%<method>s %<uri>s HTTP/1.1\" %<status>d %<bytes>d",
          **values, second: index % 60
        )
      }
    end

    def email_record(index)
      email = "user#{index}@#{%w[example.com example.org mail.test].fetch(index % 3)}"
      "Contact #{email}; backup: admin#{index}@example.net. Invalid: user@localhost."
    end

    def url_record(index)
      host = %w[example.com api.example.org cdn.example.net].fetch(index % 3)
      url = "https://#{host}/docs/#{index}?lang=en&page=#{(index % 4) + 1}"
      "See #{url}. Also https://example.com/path_(draft) and not http://."
    end

    def structured_record(values, index)
      request_id = format(
        "%<a>08x-%<b>04x-%<c>04x-%<d>04x-%<e>012x",
        a: index, b: index % 65_536, c: 0x4000 + (index % 4096),
        d: 0x8000 + (index % 4096), e: index
      )
      timestamp = format(
        "2026-08-%<day>02dT%<hour>02d:%<minute>02d:%<second>02dZ",
        day: (index % 28) + 1, hour: index % 24, minute: index % 60,
        second: index % 60
      )
      "request_id=#{request_id} timestamp=#{timestamp} level=info action=#{values[:method].downcase}"
    end

    def identifier_record(index)
      "release v#{(index % 4) + 1}.#{index % 10}.#{index % 20}; " \
        "endpoint api/users/#{index}; package pkg-client-#{index % 7}"
    end
  end

  # Raised when the two regexp implementations produce different captures.
  class DifferentialError < StandardError; end

  # Defines one application-shaped input, pattern, and extraction operation.
  class Workload
    attr_reader :name, :pattern

    DEFINITIONS = [
      {
        name: "access_log",
        input: :access_log,
        pattern: [
          %q{(?<ip>[0-9A-Fa-f:.]+) - - \[(?<timestamp>[^\]]+)\] },
          "\"(?<method>[A-Z]+) (?<uri>[^ ]+) HTTP/[0-9.]+\" ",
          "(?<status>[0-9]{3}) (?<bytes>[0-9-]+)"
        ].join
      },
      {
        name: "email",
        input: :email,
        pattern: "\\b(?<email>[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9-]+(?:\\.[A-Za-z0-9-]+)+)\\b"
      },
      {
        name: "url",
        input: :url,
        pattern: "(?<url>https?://[A-Za-z0-9.-]+(?:/[A-Za-z0-9._~/?=&%-]+)?)"
      },
      {
        name: "structured_log",
        input: :structured_log,
        pattern: "request_id=(?<request_id>[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-" \
                 "[0-9a-f]{4}-[0-9a-f]{12}) timestamp=(?<timestamp>[0-9T:-]+Z)"
      },
      {
        name: "identifier",
        input: :identifier,
        pattern: "(?<identifier>v[0-9]+\\.[0-9]+\\.[0-9]+|api/[a-z]+/[0-9]+|pkg-[a-z0-9-]+)"
      }
    ].freeze

    def self.all
      @all ||= DEFINITIONS.map { |definition| new(**definition) }.freeze
    end

    def self.find(name)
      all.find { |workload| workload.name == name } ||
        raise(ArgumentError, "unknown workload: #{name}")
    end

    def initialize(name:, input:, pattern:)
      @name = name
      @input = input
      @pattern = pattern
    end

    def extract(regexp_class, corpus)
      regexp = regexp_class.new(pattern)
      input = corpus.input(@input)
      return input.scan(regexp) if regexp_class == Regexp

      regexp.scan(input)
    end

    def assert_equivalent!(ruby_class, corpus)
      expected = extract(ruby_class, corpus)
      actual = extract(Onibi::Regexp, corpus)
      return true if expected == actual

      message = "#{name}: Ruby/Onibi extraction mismatch: " \
                "expected=#{expected.inspect} actual=#{actual.inspect}"
      raise DifferentialError, message
    end
  end

  # Runs differential checks and warm extraction measurements.
  class Runner
    def initialize(options)
      @options = options
      @corpus = Corpus.new(seed: options.fetch(:seed), records: options.fetch(:records))
      @workloads = options.fetch(:workloads).map { |name| Workload.find(name) }
    end

    def run
      require "benchmark/ips"
      @workloads.each do |workload|
        workload.assert_equivalent!(Regexp, @corpus)
        run_workload(workload)
      end
    end

    private

    def run_workload(workload)
      input = @corpus.input(workload.name)
      ruby_regexp = Regexp.new(workload.pattern)
      onibi_regexp = Onibi::Regexp.new(workload.pattern)
      puts "\n#{workload.name} records=#{@options[:records]} bytes=#{input.bytesize}"
      report_measurements(ruby_regexp, onibi_regexp, input)
      benchmark_pair(ruby_regexp, onibi_regexp, input)
    end

    def benchmark_pair(ruby_regexp, onibi_regexp, input)
      Benchmark.ips do |benchmark|
        benchmark.config(time: @options[:time], warmup: @options[:warmup])
        benchmark.report("ruby") { input.scan(ruby_regexp) }
        benchmark.report("onibi") { onibi_regexp.scan(input) }
        benchmark.compare!
      end
    end

    def report_measurements(ruby_regexp, onibi_regexp, input)
      [[:ruby, ruby_regexp], [:onibi, onibi_regexp]].each do |engine, regexp|
        report_measurement(engine, regexp, input)
      end
    end

    def report_measurement(engine, regexp, input)
      before = GC.stat
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = regexp.is_a?(Regexp) ? input.scan(regexp) : regexp.scan(input)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      after = GC.stat
      puts measurement_line(engine, result.length, elapsed, allocation_delta(before, after),
                            collection_delta(before, after))
    end

    def allocation_delta(before, after)
      after[:total_allocated_objects] - before[:total_allocated_objects]
    end

    def collection_delta(before, after)
      after[:count] - before[:count]
    end

    def measurement_line(engine, matches, elapsed, allocated, collections)
      format(
        "  %<engine>-5s matches=%<matches>-5d time=%<time>.6fs " \
        "allocated=%<allocated>d gc=%<gc>d",
        engine: engine, matches: matches, time: elapsed, allocated: allocated, gc: collections
      )
    end
  end

  # Parses command-line options for the macrobenchmark runner.
  class CLI
    def self.run(arguments)
      options = { seed: 2026, records: 1_000, time: 1.0, warmup: 0.5,
                  workloads: Workload.all.map(&:name) }
      parser = parser_for(options)
      parser.parse!(arguments)
      if options.delete(:list)
        puts Workload.all.map(&:name)
      else
        Runner.new(options).run
      end
    end

    def self.parser_for(options)
      OptionParser.new do |parser|
        parser.banner = "Usage: ruby benchmark/macro_benchmarks.rb [options]"
        add_workload_option(parser, options)
        add_corpus_options(parser, options)
        add_timing_options(parser, options)
        parser.on("--list") { options[:list] = true }
      end
    end

    def self.add_workload_option(parser, options)
      parser.on("--workload NAME", Workload.all.map(&:name)) do |value|
        options[:workloads] = [value]
      end
    end

    def self.add_corpus_options(parser, options)
      parser.on("--records N", Integer) { |value| options[:records] = value }
      parser.on("--seed N", Integer) { |value| options[:seed] = value }
    end

    def self.add_timing_options(parser, options)
      parser.on("--time SECONDS", Float) { |value| options[:time] = value }
      parser.on("--warmup SECONDS", Float) { |value| options[:warmup] = value }
    end
  end
end

MacroBenchmarks::CLI.run(ARGV) if $PROGRAM_NAME == __FILE__
