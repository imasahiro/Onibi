# frozen_string_literal: true

require "minitest/benchmark"
require "stringio"
require "test_helper"
require_relative "../../benchmark/regex-redux"

class RegexReduxTest < Minitest::Test
  INPUT = ">ONE\nAGGG TAAA\n"
  EXPECTED_OUTPUT = <<~OUTPUT.chomp
    agggtaaa|tttaccct 0
    [cgt]gggtaaa|tttaccc[acg] 0
    a[act]ggtaaa|tttacc[agt]t 0
    ag[act]gtaaa|tttac[agt]ct 0
    agg[act]taaa|ttta[agt]cct 0
    aggg[acg]aaa|ttt[cgt]ccct 0
    agggt[cgt]aa|tt[acg]accct 0
    agggta[cgt]a|t[acg]taccct 0
    agggtaa[cgt]|[acg]ttaccct 0

    15
    9
    9
  OUTPUT
  FIXTURE_EXPECTED_OUTPUT = <<~OUTPUT.chomp
    agggtaaa|tttaccct 0
    [cgt]gggtaaa|tttaccc[acg] 0
    a[act]ggtaaa|tttacc[agt]t 1
    ag[act]gtaaa|tttac[agt]ct 0
    agg[act]taaa|ttta[agt]cct 1
    aggg[acg]aaa|ttt[cgt]ccct 0
    agggt[cgt]aa|tt[acg]accct 0
    agggta[cgt]a|t[acg]taccct 0
    agggtaa[cgt]|[acg]ttaccct 2

    5161
    5000
    2455
  OUTPUT

  def test_each_engine_produces_the_expected_result
    %i[ruby onibi].each do |engine|
      result = RegexRedux.new(StringIO.new(INPUT), engine: engine).to_s

      assert_equal EXPECTED_OUTPUT, result, engine
    end
  end

  def test_each_engine_produces_the_expected_fixture_result
    input = File.read(File.expand_path("../../fasta-500.txt", __dir__))

    %i[ruby onibi].each do |engine|
      result = RegexRedux.new(StringIO.new(input), engine: engine).to_s

      assert_equal FIXTURE_EXPECTED_OUTPUT, result, engine
    end
  end

  def test_engine_can_be_selected_by_name
    assert_instance_of RegexRedux::RubyEngine, RegexRedux.engine(:ruby)
    assert_instance_of RegexRedux::OnibiEngine, RegexRedux.engine(:onibi)
    assert_equal :ruby, RegexRedux.engine_name(["--ruby"])
    assert_equal :onibi, RegexRedux.engine_name(["--engine=onibi"])
    assert_equal :onibi, RegexRedux.engine_name(["--engine", "onibi"])
  end

  def test_script_does_not_use_threads_or_forked_pattern_count
    source = File.read(File.expand_path("../../benchmark/regex-redux.rb", __dir__))

    refute_includes source, "Thread"
    refute_includes source, "forked_pattern_count"
    refute_includes source, "Process.fork"
  end
end

class RegexReduxBenchmark < Minitest::Benchmark
  INPUT = File.read(File.expand_path("../../fasta-500.txt", __dir__))

  def self.bench_range
    [1, 2]
  end

  def bench_ruby
    benchmark_engine(:ruby)
  end

  def bench_onibi
    benchmark_engine(:onibi)
  end

  private

  def benchmark_engine(engine)
    validation = proc { |_range, times| assert(times.all? { |time| time >= 0 }) }

    assert_performance(validation) do |iterations|
      iterations.times do
        RegexRedux.new(StringIO.new(INPUT), engine: engine).to_s
      end
    end
  end
end
