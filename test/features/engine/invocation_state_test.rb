# frozen_string_literal: true

require "timeout"
require "test_helper"

class InvocationStateTest < Minitest::Test
  PATTERN = "(?<word>[A-Z]+)"
  OUTER_SUBJECT = "--ALPHA!"
  INNER_SUBJECT = "xBETA?"

  def test_nested_match_keeps_each_native_result_and_mri_last_match
    regexp = Onibi::Regexp.new(PATTERN)
    expected_outer = mri_match(OUTER_SUBJECT)
    expected_inner = mri_match(INNER_SUBJECT)
    previous = ::Regexp.new("previous").match("previous")
    outer_match = nil
    inner_match = nil

    result = regexp.match(OUTER_SUBJECT) do |match|
      outer_match = match
      assert_native_match(match, expected_outer, regexp)
      assert_same previous, ::Regexp.last_match

      inner_match = regexp.match(INNER_SUBJECT)

      assert_native_match(inner_match, expected_inner, regexp)
      assert_native_match(outer_match, expected_outer, regexp)
      assert_same previous, ::Regexp.last_match
      :nested_complete
    end

    assert_equal :nested_complete, result
    assert_native_match(outer_match, expected_outer, regexp)
    assert_native_match(inner_match, expected_inner, regexp)
    assert_same previous, ::Regexp.last_match
  end

  def test_callback_exception_keeps_saved_result_and_later_match_valid
    regexp = Onibi::Regexp.new(PATTERN)
    expected_outer = mri_match(OUTER_SUBJECT)
    expected_inner = mri_match(INNER_SUBJECT)
    previous = ::Regexp.new("previous").match("previous")
    error = RuntimeError.new("callback failure")
    saved_match = nil

    raised = assert_raises(RuntimeError) do
      regexp.match(OUTER_SUBJECT) do |match|
        saved_match = match
        raise error
      end
    end

    assert_same error, raised
    assert_native_match(saved_match, expected_outer, regexp)
    next_match = regexp.match(INNER_SUBJECT)
    assert_native_match(next_match, expected_inner, regexp)
    assert_same previous, ::Regexp.last_match
  end

  def test_suspended_fiber_keeps_its_result_across_another_native_match
    regexp = Onibi::Regexp.new(PATTERN)
    expected_outer = mri_match(OUTER_SUBJECT)
    expected_inner = mri_match(INNER_SUBJECT)
    state = {}

    fiber = Fiber.new do
      regexp.match(OUTER_SUBJECT) do |match|
        state[:outer_before_suspend] = match
        Fiber.yield(match)
        state[:outer_after_resume] = match
        state[:inner] = regexp.match(INNER_SUBJECT)
        state[:outer_after_inner] = match
        :fiber_complete
      end
    end

    yielded_match = fiber.resume
    caller_match = regexp.match(INNER_SUBJECT)
    result = fiber.resume

    assert_equal :fiber_complete, result
    assert_native_match(yielded_match, expected_outer, regexp)
    assert_native_match(state[:outer_before_suspend], expected_outer, regexp)
    assert_same yielded_match, state[:outer_before_suspend]
    assert_same yielded_match, state[:outer_after_resume]
    assert_same yielded_match, state[:outer_after_inner]
    assert_native_match(state[:inner], expected_inner, regexp)
    assert_native_match(caller_match, expected_inner, regexp)
  end

  def test_threads_keep_distinct_native_results_and_mri_last_match
    regexp = Onibi::Regexp.new(PATTERN)
    subjects = { left: "--LEFT!", right: "_RIGHT!" }
    expected = subjects.transform_values { |subject| mri_match(subject) }
    ready = Queue.new
    release = Queue.new

    threads = subjects.map do |name, subject|
      Thread.new do
        previous = ::Regexp.new("marker-#{name}").match("marker-#{name}")
        before_match = ::Regexp.last_match.equal?(previous)
        block_result = regexp.match(subject) do |match|
          ready << name
          release.pop
          [match, ::Regexp.last_match.equal?(previous)]
        end
        [name, block_result, before_match, ::Regexp.last_match.equal?(previous)]
      end
    end

    begin
      ready_names = Timeout.timeout(5) do
        Array.new(subjects.length) { ready.pop }
      end
    ensure
      subjects.length.times { release << true }
    end

    results = Timeout.timeout(5) { threads.map(&:value) }
    assert_equal subjects.keys.sort, ready_names.sort

    results.each do |entry|
      name, block_result, last_match_before, last_match_after = entry
      match, last_match_during = block_result
      assert_native_match(match, expected.fetch(name), regexp)
      assert last_match_before
      assert last_match_during
      assert last_match_after
    end
  end

  private

  def mri_match(subject)
    ::Regexp.new(PATTERN).match(subject)
  end

  def assert_native_match(actual, expected, regexp)
    assert_instance_of Onibi::MatchData, actual
    assert_same regexp, actual.regexp
    assert_equal expected[0], actual[0]
    assert_equal expected[:word], actual[:word]
    assert_equal expected.begin(0), actual.begin(0)
    assert_equal expected.end(0), actual.end(0)
    assert_equal expected.begin(:word), actual.begin(:word)
    assert_equal expected.end(:word), actual.end(:word)
  end
end
