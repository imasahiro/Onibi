# frozen_string_literal: true

require_relative "../../test_helper"

class CandidateSourceTest < Minitest::Test
  Source = Struct.new(:candidates) do
    include Onibi::Codegen::CandidateSource

    def eligible?(_input, _position) = true
    def candidate_positions(_input, _position) = candidates
  end

  def test_intersection_preserves_order_and_removes_duplicate_candidates
    source = Onibi::Codegen::CandidateSource::Intersection.new(
      [Source.new([1, 3, 5, 7]), Source.new([0, 3, 5, 8])]
    )

    assert_equal [3, 5], source.candidate_positions("input", 0)
    assert source.preserves_order?
  end

  def test_intersection_stops_after_an_empty_source
    first = CountingSource.new([])
    second = CountingSource.new([1, 2, 3])

    source = Onibi::Codegen::CandidateSource::Intersection.new([first, second])

    assert_empty source.candidate_positions("input", 0)
    assert_equal 1, first.calls
    assert_equal 0, second.calls
  end

  class CountingSource
    include Onibi::Codegen::CandidateSource
    attr_reader :calls

    def initialize(candidates)
      @candidates = candidates
      @calls = 0
    end

    def eligible?(_input, _position) = true

    def candidate_positions(_input, _position)
      @calls += 1
      @candidates
    end
  end
end
