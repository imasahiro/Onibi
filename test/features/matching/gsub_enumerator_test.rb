# frozen_string_literal: true

require "objspace"
require "test_helper"
require "weakref"

class GsubEnumeratorTest < Minitest::Test
  def test_creation_has_unknown_size_and_defers_subject_conversion
    events = []
    calls = 0
    subject = Object.new
    subject.define_singleton_method(:to_str) do
      calls += 1
      events << [:to_str, calls]
      calls.odd? ? "aba" : "bab"
    end
    regexp = Onibi::Regexp.new("[ab]")
    enumerator = regexp.gsub(subject)
    mri_enumerator = "aba".gsub(/[ab]/)

    assert_instance_of Enumerator, enumerator
    assert_equal mri_enumerator.class, enumerator.class
    assert_nil mri_enumerator.size
    assert_nil enumerator.size
    assert_empty events

    first_values = []
    first_result = enumerator.each do |value|
      first_values << value.dup
      "X"
    end
    assert_equal %w[a b a], first_values
    assert_equal "XXX", first_result
    assert_equal [[:to_str, 1]], events

    second_values = []
    second_result = enumerator.each do |value|
      second_values << value.dup
      "Y"
    end
    assert_equal %w[b a b], second_values
    assert_equal "YYY", second_result
    assert_equal [[:to_str, 1], [:to_str, 2]], events
  end

  def test_subject_conversion_errors_wait_until_iteration
    events = []
    bad_subject = Object.new
    bad_subject.define_singleton_method(:to_str) do
      events << :to_str
      1
    end

    enumerator = Onibi::Regexp.new("a").gsub(bad_subject)
    assert_instance_of Enumerator, enumerator
    assert_nil enumerator.size
    assert_empty events
    assert_raises(TypeError) { enumerator.next }
    assert_equal [:to_str], events

    events.clear
    raising_subject = Object.new
    raising_subject.define_singleton_method(:to_str) do
      events << :to_str
      raise "subject conversion failed"
    end
    enumerator = Onibi::Regexp.new("a").gsub(raising_subject)
    assert_empty events
    error = assert_raises(RuntimeError) { enumerator.each { "X" } }
    assert_equal "subject conversion failed", error.message
    assert_equal [:to_str], events
  end

  def test_each_yields_whole_matches_and_returns_the_result_string
    [["a", "aba"], ["", "ab"], ["(?=a)", "ba"], ["z", "aba"], ["", ""]].each do |pattern, source|
      expected_values = []
      expected_subject = source.dup
      expected_result = expected_subject.gsub(::Regexp.new(pattern)) do |value|
        expected_values << value.dup
        "X"
      end

      actual_values = []
      actual_subject = source.dup
      enumerator = Onibi::Regexp.new(pattern).gsub(actual_subject)
      assert_instance_of Enumerator, enumerator, pattern
      assert_nil enumerator.size, pattern
      actual_result = enumerator.each do |value|
        actual_values << value.dup
        "X"
      end

      assert_equal expected_values, actual_values, pattern
      assert_equal expected_result, actual_result, pattern
      refute_same actual_subject, actual_result, pattern
    end
  end

  def test_frozen_and_binary_subjects_preserve_yield_encoding
    frozen_subject = "é"
    assert_predicate frozen_subject, :frozen?
    expected_frozen_values = []
    expected_frozen_result = frozen_subject.dup.gsub(::Regexp.new("é")) do |value|
      expected_frozen_values << [value.dup, value.encoding]
      "X"
    end
    frozen_enum = Onibi::Regexp.new("é").gsub(frozen_subject)
    frozen_values = []
    frozen_result = frozen_enum.each do |value|
      frozen_values << [value.dup, value.encoding]
      "X"
    end
    assert_equal expected_frozen_result, frozen_result
    assert_equal expected_frozen_values, frozen_values

    binary_subject = "\xE9".b
    binary_pattern = "\xE9".b
    expected_binary_values = []
    expected_binary_result = binary_subject.dup.gsub(::Regexp.new(binary_pattern)) do |value|
      expected_binary_values << [value.bytes, value.encoding]
      "X".b
    end
    binary_values = []
    binary_result = Onibi::Regexp.new(binary_pattern).gsub(binary_subject).each do |value|
      binary_values << [value.bytes, value.encoding]
      "X".b
    end
    assert_equal expected_binary_result, binary_result
    assert_equal expected_binary_values, binary_values
  end

  def test_peek_next_feed_and_stop_iteration_result
    expected = peek_feed_observation(:mri)
    actual = peek_feed_observation(:onibi)
    assert_equal expected, actual
    assert_equal "a!", actual.fetch(:peeked)
    assert_equal "XY", actual.fetch(:stop_result)
    assert_equal "", actual.fetch(:default_result)
  end

  def test_nil_feed_matches_mri
    expected = nil_feed_observation(:mri)
    actual = nil_feed_observation(:onibi)
    assert_equal expected, actual
    assert_equal "a", actual.fetch(:match)
    assert_equal "b", actual.fetch(:result)
  end

  def test_feed_error_restarts_at_first_distinct_match_and_rewind_restarts
    expected = feed_error_observation(:mri)
    actual = feed_error_observation(:onibi)
    assert_equal expected, actual
    assert_equal "a", actual.fetch(:after_error)
    assert_equal "b", actual.fetch(:restart_second)
    assert_equal "<restart-1><restart-2>", actual.fetch(:restart_result)
    assert_equal "<rewind-1><rewind-2>", actual.fetch(:rewind_result)
  end

  def test_subject_changes_before_iteration_and_rewind_are_observed
    assert_equal subject_mutation_observation(:mri),
                 subject_mutation_observation(:onibi)
  end

  def test_length_change_while_suspended_raises_like_mri
    assert_equal length_change_observation(:mri),
                 length_change_observation(:onibi)
  end

  def test_repeated_each_matches_mri
    assert_equal repeated_each_observation(:mri),
                 repeated_each_observation(:onibi)
  end

  def test_explicit_nil_arity_and_replacement_precedence
    regexp = Onibi::Regexp.new("a")
    mri = ::Regexp.new("a")
    expected_enum = "a".gsub(mri)
    actual_enum = regexp.gsub("a")
    assert_equal expected_enum.class, actual_enum.class
    assert_nil expected_enum.size
    assert_nil actual_enum.size
    expected_block_result = "a".gsub(mri) { "X" }
    actual_block_result = regexp.gsub("a") { "X" }
    assert_equal expected_block_result, actual_block_result
    assert_instance_of String, actual_block_result

    [false, true].each do |with_block|
      expected = if with_block
                   assert_raises(TypeError) { "a".gsub(mri, nil) { "X" } }
                 else
                   assert_raises(TypeError) { "a".gsub(mri, nil) }
                 end
      actual = if with_block
                 assert_raises(TypeError) { regexp.gsub("a", nil) { "X" } }
               else
                 assert_raises(TypeError) { regexp.gsub("a", nil) }
               end
      assert_equal expected.class, actual.class
    end

    expected_zero = assert_raises(ArgumentError) { "a".gsub }
    actual_zero = assert_raises(ArgumentError) { regexp.gsub }
    assert_equal expected_zero.class, actual_zero.class
    expected_many = assert_raises(ArgumentError) { "a".gsub(mri, "X", "Y") }
    actual_many = assert_raises(ArgumentError) { regexp.gsub("a", "X", "Y") }
    assert_equal expected_many.class, actual_many.class

    expected_block_called = false
    expected_string_result = "aba".gsub(mri, "R") do
      expected_block_called = true
    end
    actual_block_called = false
    actual_string_result = regexp.gsub("aba", "R") do
      actual_block_called = true
    end
    assert_equal expected_string_result, actual_string_result
    assert_equal expected_block_called, actual_block_called
    refute actual_block_called

    expected_hash_called = false
    expected_hash_result = "aba".gsub(mri, { "a" => "H" }) do
      expected_hash_called = true
    end
    actual_hash_called = false
    actual_hash_result = regexp.gsub("aba", { "a" => "H" }) do
      actual_hash_called = true
    end
    assert_equal expected_hash_result, actual_hash_result
    assert_equal expected_hash_called, actual_hash_called
    refute actual_hash_called
  end

  def test_native_iteration_has_no_string_gsub_call_and_fallback_is_visible
    native = Onibi::Regexp.new("a")
    native_result, native_calls = trace_string_gsub do
      native.gsub("aba").each { "X" }
    end
    assert_equal "XbX", native_result
    assert_empty native_calls
    native_diagnostics = native.send(:__onibi_diagnostics__, "aba")
    assert native_diagnostics.fetch(:rseq)
    assert_equal 0, native_diagnostics.fetch(:fallback)

    fallback = Onibi::Regexp.new("\\X")
    fallback_values = []
    fallback_result, fallback_calls = trace_string_gsub do
      fallback.gsub("é").each do |value|
        fallback_values << value.dup
        "X"
      end
    end
    assert_equal "X", fallback_result
    assert_equal ["é"], fallback_values
    assert_equal 1, fallback_calls.length
    fallback_diagnostics = fallback.send(:__onibi_diagnostics__, "é")
    refute fallback_diagnostics.fetch(:rseq)
    assert_equal 1, fallback_diagnostics.fetch(:fallback)
    assert_equal :grapheme, fallback_diagnostics.fetch(:fallback_reason)
  end

  def test_each_break_throw_and_error_allow_reuse
    assert_equal unwind_observation(:mri), unwind_observation(:onibi)
  end

  def test_direct_enumerator_retains_and_releases_capture_owner
    collect_gc
    baseline_count = private_capture_owners.length
    owner_ref = complete_suspended_enumerator(baseline_count)
    collect_gc
    refute owner_ref.weakref_alive?
    assert_equal baseline_count, private_capture_owners.length

    weak_enumerator, weak_subject, weak_regexp = abandoned_direct_enumerator
    collect_gc
    refute weak_enumerator.weakref_alive?
    refute weak_subject.weakref_alive?
    refute weak_regexp.weakref_alive?
    assert_equal baseline_count, private_capture_owners.length
  end

  private

  def unwind_observation(engine)
    enumerator = enumerator_for(engine, +"aba", "a")
    stopped = enumerator.each do |value|
      break :stopped if value == "a"
    end
    break_reuse = enumerator.each { "X" }

    enumerator = enumerator_for(engine, +"aba", "a")
    thrown = catch(:gsub_enumerator_stop) do
      enumerator.each do |value|
        throw :gsub_enumerator_stop, :thrown if value == "a"
      end
    end
    throw_reuse = enumerator.each { "X" }

    enumerator = enumerator_for(engine, +"aba", "a")
    error = assert_raises(RuntimeError) do
      enumerator.each do |value|
        raise "block failed" if value == "a"
      end
    end
    error_reuse = enumerator.each { "X" }
    {
      break_result: stopped,
      break_reuse: break_reuse,
      throw_result: thrown,
      throw_reuse: throw_reuse,
      error: [error.class.name, error.message],
      error_reuse: error_reuse
    }
  end

  def enumerator_for(engine, subject, pattern)
    return subject.gsub(::Regexp.new(pattern)) if engine == :mri

    Onibi::Regexp.new(pattern).gsub(subject)
  end

  def peek_feed_observation(engine)
    events = []
    feed = Object.new
    feed.define_singleton_method(:to_s) do
      events << :to_s
      "X"
    end
    subject = +"ab"
    enumerator = enumerator_for(engine, subject, "[ab]")
    peeked = enumerator.peek
    first = enumerator.next
    first_same = first.equal?(peeked)
    first_mutable = !first.frozen?
    first << "!"
    original_subject = subject.dup
    enumerator.feed(feed)
    events_after_feed = events.dup
    second = enumerator.next
    events_after_resume = events.dup
    enumerator.feed("Y")
    stopped = assert_raises(StopIteration) { enumerator.next }
    default_feed = enumerator_for(engine, +"a", "a")
    default_match = default_feed.next
    default_stop = assert_raises(StopIteration) { default_feed.next }
    {
      peeked: peeked,
      first_same: first_same,
      first_mutable: first_mutable,
      original_subject: original_subject,
      second: second,
      events_after_feed: events_after_feed,
      events_after_resume: events_after_resume,
      stop_result: stopped.result,
      default_match: default_match,
      default_result: default_stop.result
    }
  end

  def nil_feed_observation(engine)
    enumerator = enumerator_for(engine, +"ab", "a")
    match = enumerator.next
    enumerator.feed(nil)
    stopped = assert_raises(StopIteration) { enumerator.next }
    { match: match, result: stopped.result }
  end

  def feed_error_observation(engine)
    events = []
    bad_feed = Object.new
    bad_feed.define_singleton_method(:to_s) do
      events << :to_s
      raise "replacement conversion failed"
    end
    enumerator = enumerator_for(engine, +"ab", "[ab]")
    first = enumerator.next
    enumerator.feed(bad_feed)
    error = assert_raises(RuntimeError) { enumerator.next }
    after_error = enumerator.next
    enumerator.feed("<restart-1>")
    restart_second = enumerator.next
    enumerator.feed("<restart-2>")
    restart_stop = assert_raises(StopIteration) { enumerator.next }
    enumerator.rewind
    rewind_first = enumerator.next
    enumerator.feed("<rewind-1>")
    rewind_second = enumerator.next
    enumerator.feed("<rewind-2>")
    rewind_stop = assert_raises(StopIteration) { enumerator.next }
    {
      first: first,
      error: [error.class.name, error.message],
      after_error: after_error,
      restart_second: restart_second,
      restart_result: restart_stop.result,
      rewind_first: rewind_first,
      rewind_second: rewind_second,
      rewind_result: rewind_stop.result,
      events: events
    }
  end

  def subject_mutation_observation(engine)
    subject = +"aba"
    enumerator = enumerator_for(engine, subject, "a")
    subject.replace("bbb")
    before_iteration = enumerator.each { "X" }

    subject.replace("aba")
    enumerator = enumerator_for(engine, subject, "a")
    first = enumerator.next
    subject.replace("aca")
    enumerator.feed("X")
    second = enumerator.next
    enumerator.feed("Y")
    stopped = assert_raises(StopIteration) { enumerator.next }
    subject.replace("bbb")
    enumerator.rewind
    rewound = assert_raises(StopIteration) { enumerator.next }
    {
      before_iteration: before_iteration,
      first: first,
      second: second,
      same_length_result: stopped.result,
      rewind_result: rewound.result
    }
  end

  def length_change_observation(engine)
    subject = +"aba"
    enumerator = enumerator_for(engine, subject, "a")
    first = enumerator.next
    subject.replace("b")
    enumerator.feed("X")
    error = assert_raises(RuntimeError) { enumerator.next }
    [first, error.class.name, error.message]
  end

  def repeated_each_observation(engine)
    enumerator = enumerator_for(engine, +"aba", "a")
    2.times.map do |index|
      values = []
      replacement = index.zero? ? "X" : "Y"
      result = enumerator.each do |value|
        values << value.dup
        replacement
      end
      [values, result]
    end
  end

  def complete_suspended_enumerator(baseline_count)
    regexp = Onibi::Regexp.new("(a)")
    subject = +"a"
    enumerator = regexp.gsub(subject)
    assert_equal baseline_count, private_capture_owners.length

    assert_equal "a", enumerator.next
    owner_ref = new_capture_owner_ref(baseline_count)
    collect_gc
    assert owner_ref.weakref_alive?

    enumerator.feed("X")
    stopped = assert_raises(StopIteration) { enumerator.next }
    assert_equal "X", stopped.result
    owner_ref
  end

  def new_capture_owner_ref(baseline_count)
    owners = private_capture_owners
    assert_equal baseline_count + 1, owners.length
    WeakRef.new(owners.last)
  end

  def trace_string_gsub(&block)
    calls = []
    trace = TracePoint.new(:c_call) do |event|
      next unless event.method_id == :gsub && event.defined_class == String

      calls << event.self.class.name
    end
    result = trace.enable(&block)
    [result, calls]
  end

  def private_capture_owners
    ObjectSpace.each_object(Object).filter_map do |object|
      object if ObjectSpace.dump(object).include?('"struct":"OnibiCaptureRangeOwner"')
    end
  end

  def collect_gc
    3.times do
      GC.start(full_mark: true, immediate_sweep: true)
      GC.compact if GC.respond_to?(:compact)
    end
  end

  def abandoned_direct_enumerator
    subject = +"a"
    regexp = Onibi::Regexp.new("(a)")
    enumerator = regexp.gsub(subject)
    enumerator.next
    [WeakRef.new(enumerator), WeakRef.new(subject), WeakRef.new(regexp)]
  end
end
