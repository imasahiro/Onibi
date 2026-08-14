# frozen_string_literal: true

require "test_helper"
require_relative "../../../benchmark/macro_benchmarks"

class MacroBenchmarksTest < Minitest::Test
  def test_generation_is_deterministic
    first = MacroBenchmarks::Corpus.new(seed: 123, records: 20).to_h
    second = MacroBenchmarks::Corpus.new(seed: 123, records: 20).to_h

    assert_equal first, second
  end

  def test_workloads_have_expected_names
    assert_equal %w[access_log email url structured_log identifier],
                 MacroBenchmarks::Workload.all.map(&:name)
  end

  def test_each_workload_matches_ruby_regexp
    corpus = MacroBenchmarks::Corpus.new(seed: 7, records: 40)

    MacroBenchmarks::Workload.all.each do |workload|
      expected = workload.extract(::Regexp, corpus)
      actual = workload.extract(Onibi::Regexp, corpus)

      assert_equal expected, actual, workload.name
    end
  end

  def test_runner_rejects_differential_mismatch
    workload = MacroBenchmarks::Workload.all.first
    corpus = MacroBenchmarks::Corpus.new(seed: 7, records: 2)
    fake = Class.new do
      def self.new(*)
        Object.new.tap { |object| object.define_singleton_method(:scan) { |_input| [] } }
      end
    end

    error = assert_raises(MacroBenchmarks::DifferentialError) do
      workload.assert_equivalent!(fake, corpus)
    end

    assert_match(/access_log/, error.message)
  end
end
