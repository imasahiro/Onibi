# frozen_string_literal: true

require "test_helper"

class MatchDataPayloadTest < Minitest::Test
  def assert_raises_with_message(error_class, message, &block)
    error = assert_raises(error_class, &block)
    assert_match message, error.message
  end

  def payload(regexp, subject, ranges)
    Onibi::MatchData.send(:__onibi_new__, regexp, subject, ranges)
  end

  def summary(match_data)
    match_data.send(:__onibi_match_data_diagnostics__)
  end

  def test_public_allocation_cannot_publish_an_unchecked_payload
    assert_raises(TypeError) { Onibi::MatchData.new }
  end

  def test_constructor_copies_registers_and_subject_before_caller_cleanup
    regexp = Onibi::Regexp.new("(?<word>word)")
    subject = String.new("xxwordyy")
    ranges = [[2, 6], [2, 6]]
    match_data = payload(regexp, subject, ranges)

    ranges[0][0] = 0
    ranges[1][1] = 2
    subject.replace("changed")
    GC.start

    info = summary(match_data)
    assert_equal [[2, 6], [2, 6]], info[:raw_registers]
    assert_equal "xxwordyy", info[:subject]
    assert info[:subject_frozen]
  end

  def test_metadata_is_copied_and_duplicate_indices_are_retained
    regexp = Onibi::Regexp.new("(?<word>a)(?<word>b)")
    match_data = payload(regexp, "ab", [[0, 2], [0, 1], [1, 2]])
    info = summary(match_data)

    assert_equal ["word"], info[:names]
    assert_equal [1, 2], info[:named_index]["word"]
    info[:names] << "changed"
    info[:named_index]["word"] << 99
    assert_equal ["word"], summary(match_data)[:names]
    assert_equal [1, 2], summary(match_data)[:named_index]["word"]
  end

  def test_empty_unmatched_multibyte_and_outside_group_zero_ranges_are_valid
    regexp = Onibi::Regexp.new("(?<empty>)(?<missing>a)?")
    match_data = payload(regexp, "éa", [[0, 3], [0, 0], [-1, -1]])

    assert_equal [[0, 3], [0, 0], [-1, -1]], summary(match_data)[:raw_registers]

    outside = payload(Onibi::Regexp.new("(b)"), "ab", [[1, 2], [0, 2]])
    assert_equal [[1, 2], [0, 2]], summary(outside)[:raw_registers]
  end

  def test_invalid_register_shapes_are_rejected_before_publication
    regexp = Onibi::Regexp.new("(a)")
    assert_raises_with_message(ArgumentError, /non-empty array/) do
      payload(regexp, "a", [])
    end
    assert_raises_with_message(RangeError, /half-unmatched/) do
      payload(regexp, "a", [[0, 1], [0, -1]])
    end
    assert_raises_with_message(RangeError, /out of bounds/) do
      payload(regexp, "a", [[0, 1], [2, 1]])
    end
    assert_raises_with_message(RangeError, /out of bounds/) do
      payload(regexp, "a", [[0, 2], [0, 1]])
    end
    assert_raises_with_message(RangeError, /no full capture/) do
      payload(regexp, "a", [[-2, -2]])
    end
    assert_raises(ArgumentError) { payload(regexp, "a", "not ranges") }
  end

  def test_range_coercion_error_releases_heap_diagnostic_storage
    regexp = Onibi::Regexp.new("(a)")
    bad_integer = Object.new
    bad_integer.define_singleton_method(:to_int) { raise TypeError, "bad int" }

    info = regexp.send(:__onibi_match_data_failure_diagnostics__,
                       "a", [[0, 1], [bad_integer, 1]], 0)
    assert info[:raised]
    assert_equal info[:before], info[:after]
    assert_equal TypeError, info[:error]
  end

  def test_lookahead_capture_outside_group_zero_keeps_valid_bytes
    source = "(?=(a))"
    expected = ::Regexp.new(source).match("a")
    assert_equal [[0, 0], [0, 1]], [expected.offset(0), expected.offset(1)]

    match_data = payload(Onibi::Regexp.new(source), "a", [[0, 0], [0, 1]])
    assert_equal [[0, 0], [0, 1]], summary(match_data)[:raw_registers]
  end

  def test_native_diagnostic_constructor_copies_raw_search_result
    regexp = Onibi::Regexp.new("(?<letter>a)(b)?")
    info = regexp.send(:__onibi_match_data_diagnostics__, "a")

    assert_equal 3, info[:num_regs]
    assert_equal [[0, 1], [0, 1], [-1, -1]], info[:raw_registers]
    assert_equal ["letter"], info[:names]
    assert info[:lazy_character_cache]
  end

  def test_injected_constructor_failures_release_native_register_storage
    regexp = Onibi::Regexp.new("(?<letter>a)")
    1.upto(4) do |stage|
      info = regexp.send(:__onibi_match_data_failure_diagnostics__,
                         "a", [[0, 1], [0, 1]], stage)
      assert info[:raised], stage
      assert_equal info[:before], info[:after], stage
    end
  end

  def test_payload_survives_bounded_gc_stress
    regexp = Onibi::Regexp.new("(?<letter>é)")
    previous = GC.stress
    GC.stress = true
    match_data = payload(regexp, "é", [[0, 2], [0, 2]])
    20.times do
      Object.new
      GC.start
      GC.compact
    end
    assert_equal [[0, 2], [0, 2]], summary(match_data)[:raw_registers]
  ensure
    GC.stress = previous
  end
end
