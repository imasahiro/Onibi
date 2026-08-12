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

  def test_union_merges_ordered_sources_and_removes_duplicates
    source = Onibi::Codegen::CandidateSource::Union.new(
      [Source.new([1, 5, 9]), Source.new([2, 5, 8]), Source.new([0, 4, 10])]
    )

    assert_equal [0, 1, 2, 4, 5, 8, 9, 10], source.candidate_positions("input", 0)
    assert source.preserves_order?
  end

  def test_union_skips_ineligible_sources
    source = Onibi::Codegen::CandidateSource::Union.new(
      [EligibilitySource.new([], false), EligibilitySource.new([2, 4], true)]
    )

    assert_equal [2, 4], source.candidate_positions("input", 0)
    assert source.eligible?("input", 0)
  end

  def test_singleton_byte_set_uses_string_search_without_getbyte
    source = Onibi::Experimental::Swar::ByteSetPrefilter.new(["a".ord])
    input = GetbyteForbiddenString.new("xxaaxa")

    assert_equal [2, 3, 5], source.candidate_positions(input, 0)
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

  class EligibilitySource < Source
    def initialize(candidates, eligible)
      super(candidates)
      @eligible = eligible
    end

    def eligible?(_input, _position)
      @eligible
    end
  end

  class GetbyteForbiddenString < String
    def getbyte(_index)
      raise "singleton byte search must not call getbyte"
    end
  end
end
