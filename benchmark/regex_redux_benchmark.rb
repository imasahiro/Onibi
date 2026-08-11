# frozen_string_literal: true

require "benchmark"
require "stringio"
require_relative "../regex-redux"

class RegexReduxBenchmark
  DEFAULT_ITERATIONS = 1

  def self.run(input_path:, engines:, iterations:)
    input = File.read(input_path)
    benchmark = new(input, engines, iterations)
    benchmark.run
  end

  def initialize(input, engines, iterations)
    @input = input
    @engines = engines
    @iterations = iterations
  end

  def run
    Benchmark.bmbm(12) do |report|
      @engines.each do |engine|
        report.report(engine.to_s) do
          @iterations.times do
            RegexRedux.new(StringIO.new(@input), engine: engine).to_s
          end
        end
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  arguments = ARGV.dup
  engine = nil
  iterations = RegexReduxBenchmark::DEFAULT_ITERATIONS
  input_path = File.expand_path("../fasta-500.txt", __dir__)

  until arguments.empty?
    argument = arguments.shift
    case argument
    when "--engine"
      engine = arguments.shift.to_sym
    when /^--engine=(.+)$/
      engine = Regexp.last_match(1).to_sym
    when "--iterations", "-n"
      iterations = Integer(arguments.shift)
    when /^--iterations=(.+)$/
      iterations = Integer(Regexp.last_match(1))
    else
      input_path = argument
    end
  end

  engines = engine ? [engine] : %i[ruby onibi]
  RegexReduxBenchmark.run(input_path: input_path, engines: engines, iterations: iterations)
end
