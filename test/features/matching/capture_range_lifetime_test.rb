# frozen_string_literal: true

require "objspace"
require "test_helper"
require "weakref"

class CaptureRangeLifetimeTest < Minitest::Test
  class CallbackError < StandardError; end

  LIFETIME_KINDS = %i[scan_block gsub_block hash_default hash_to_s].freeze
  LIFETIME_MODES = %i[normal error throw resume].freeze

  def test_callback_lifecycles_match_mri
    LIFETIME_KINDS.each do |kind|
      LIFETIME_MODES.each do |mode|
        expected = run_lifecycle(:mri, kind, mode)
        actual = run_lifecycle(:onibi, kind, mode)
        assert_equal expected, actual, "#{kind}/#{mode}"
      end
    end
  end

  def test_callback_owners_are_visible_during_suspension_and_collect_after_abandonment
    collect_gc
    baseline_count = private_capture_owners.length

    LIFETIME_KINDS.each do |kind|
      released_bytes, weak_fiber = complete_suspended_call(kind, baseline_count)
      assert_equal 32, released_bytes, kind
      collect_gc
      refute weak_fiber.weakref_alive?, kind
      assert_equal baseline_count, private_capture_owners.length, kind

      weak_fiber, weak_subject = abandoned_call(kind)
      collect_gc
      refute weak_fiber.weakref_alive?, kind
      refute weak_subject.weakref_alive?, kind
      assert_equal baseline_count, private_capture_owners.length, kind
    end
  end

  def test_owner_size_tracks_capture_width_and_ensure_release
    collect_gc
    baseline_count = private_capture_owners.length
    released_bytes = complete_capture_width_calls(baseline_count)
    assert_equal [48, 64], released_bytes.sort
    collect_gc
    assert_equal baseline_count, private_capture_owners.length
  end

  def test_external_enumerators_resume_and_abandon_like_mri
    %i[scan gsub].each do |kind|
      expected = run_external_enumerator(:mri, kind)
      actual = run_external_enumerator(:onibi, kind)
      assert_equal expected, actual, kind

      %i[mri onibi].each do |engine|
        weak_enumerator, weak_subject = abandoned_external_enumerator(engine, kind)
        collect_gc
        refute weak_enumerator.weakref_alive?, "#{engine}/#{kind}"
        refute weak_subject.weakref_alive?, "#{engine}/#{kind}"
      end
    end
  end

  def test_capture_widths_zero_width_misses_and_replacements_match_mri
    [
      ["a", "aba"],
      ["(a)(b)?", "aab"],
      ["((a)(b)?)", "abab"],
      ["()()", "ab"],
      ["z", "aba"]
    ].each do |pattern, source|
      onibi = Onibi::Regexp.new(pattern)
      assert_native_route(onibi, source)
      mri = Regexp.new(pattern)

      assert_equal source.scan(mri), onibi.scan(source), pattern
      expected_values = []
      actual_values = []
      expected = source.gsub(mri) do |value|
        expected_values << snapshot(value)
        "X"
      end
      actual = onibi.gsub(source) do |value|
        actual_values << snapshot(value)
        "X"
      end
      assert_equal expected, actual, pattern
      assert_equal expected_values, actual_values, pattern
    end

    regexp = Onibi::Regexp.new("(a)")
    source = "aba"
    assert_native_route(regexp, source)
    assert_equal source.gsub(Regexp.new("(a)"), "<\\1>"),
                 regexp.gsub(source, "<\\1>")

    miss = Onibi::Regexp.new("(z)")
    assert_native_route(miss, source)
    assert_equal source.gsub(Regexp.new("(z)"), "<\\1>"),
                 miss.gsub(source, "<\\1>")
    assert_empty miss.scan(source)
  end

  def test_existing_grapheme_fallback_boundary_stays_explicit
    source = "éあ"
    regexp = Onibi::Regexp.new("(\\X)")
    diagnostic = regexp.send(:__onibi_diagnostics__, source)
    refute diagnostic.fetch(:rseq)
    assert_equal 1, diagnostic.fetch(:fallback)
    assert_equal :grapheme, diagnostic.fetch(:fallback_reason)

    expected = source.gsub(Regexp.new("(\\X)")) { |match| "<#{match}>" }
    actual = regexp.gsub(source) { |match| "<#{match}>" }
    assert_equal expected, actual
    assert_equal source.scan(Regexp.new("(\\X)")), regexp.scan(source)
  end

  def test_nested_native_calls_keep_repeated_outer_matches_valid
    outer = Onibi::Regexp.new("(a)(b)?")
    inner_scan = Onibi::Regexp.new("(b)(c)?")
    inner_gsub = Onibi::Regexp.new("(b)")
    source = "aba"
    assert_native_route(outer, source)
    assert_native_route(inner_scan, "bc")
    assert_native_route(inner_gsub, "bb")

    observed = []
    result = outer.scan(source) do |captures|
      GC.start(full_mark: true, immediate_sweep: true)
      GC.compact
      observed << [snapshot(captures), inner_scan.scan("bc"),
                   inner_gsub.gsub("bb") { "X" }]
    end

    assert_same source, result
    expected = source.scan(Regexp.new("(a)(b)?")).map do |captures|
      [snapshot(captures), Regexp.new("(b)(c)?").then { |regexp| "bc".scan(regexp) },
       "bb".gsub(Regexp.new("(b)")) { "X" }]
    end
    assert_equal expected, observed
  end

  private

  def engine_regexp(engine, pattern)
    engine == :onibi ? Onibi::Regexp.new(pattern) : Regexp.new(pattern)
  end

  def assert_native_route(regexp, subject)
    route = regexp.send(:__onibi_diagnostics__, subject)
    assert route.fetch(:rseq), route.inspect
    assert_equal 0, route.fetch(:fallback), route.inspect
    assert_includes [0, 1], route.fetch(:status), route.inspect
    route
  end

  def snapshot(value)
    case value
    when String
      { bytes: value.bytes, encoding: value.encoding.name }
    when Array
      value.map { |item| snapshot(item) }
    else
      value
    end
  end

  def collect_gc
    10.times do
      GC.start(full_mark: true, immediate_sweep: true)
      GC.compact if GC.respond_to?(:compact)
    end
  end

  def private_capture_owners
    ObjectSpace.each_object(Object).filter_map do |object|
      object if ObjectSpace.dump(object).include?('"struct":"OnibiCaptureRangeOwner"')
    end
  end

  def expected_call_result(kind, subject)
    return snapshot(subject) if kind == :scan_block

    replacement = { gsub_block: "X", hash_default: "D", hash_to_s: "T" }.fetch(kind)
    snapshot(replacement)
  end

  def complete_suspended_call(kind, baseline_count)
    fiber, subject, _regexp = start_suspended_call(kind)
    weak_fiber = WeakRef.new(fiber)
    weak_owner, suspended_size = observe_suspended_owner(baseline_count)
    collect_gc
    assert weak_owner.weakref_alive?, kind
    owner = weak_owner.__getobj__
    assert_equal suspended_size, ObjectSpace.memsize_of(owner), kind

    result = fiber.resume(:continue)
    assert_equal expected_call_result(kind, subject), snapshot(result), kind
    collect_gc
    [suspended_size - ObjectSpace.memsize_of(owner), weak_fiber]
  end

  def observe_suspended_owner(baseline_count)
    owners = private_capture_owners
    assert_equal baseline_count + 1, owners.length
    owner = owners.drop(baseline_count).fetch(0)
    [WeakRef.new(owner), ObjectSpace.memsize_of(owner)]
  end

  def complete_capture_width_calls(baseline_count)
    small_fiber = suspended_scan("(a)(b)?", "a")
    large_fiber = suspended_scan("((a)(b)?)", "ab")
    collect_gc
    owners = private_capture_owners
    assert_equal baseline_count + 2, owners.length
    new_owners = owners.drop(baseline_count)
    before_sizes = new_owners.map { |owner| ObjectSpace.memsize_of(owner) }.sort
    assert_equal 16, before_sizes.last - before_sizes.first

    small_fiber.resume(:continue)
    large_fiber.resume(:continue)
    collect_gc
    after_sizes = new_owners.map { |owner| ObjectSpace.memsize_of(owner) }.sort
    before_sizes.zip(after_sizes).map { |before, after| before - after }
  end

  def run_lifecycle(engine, kind, mode)
    pattern = "(a)"
    subject = String.new(mode == :resume ? "a" : "aa")
    regexp = engine_regexp(engine, pattern)
    assert_native_route(regexp, subject) if engine == :onibi
    events = []
    notify = lambda do |value|
      events << snapshot(value)
      case mode
      when :error
        raise CallbackError, "callback failed"
      when :throw
        throw :capture_range_lifetime, :thrown
      when :resume
        Fiber.yield(:paused)
      end
    end

    operation = lambda do
      case kind
      when :scan_block
        scan_call(engine, regexp, subject) { |value| notify.call(value) }
      when :gsub_block
        gsub_call(engine, regexp, subject) do |value|
          notify.call(value)
          "X"
        end
      when :hash_default
        replacement = Hash.new do |_hash, key|
          notify.call(key)
          "D"
        end
        gsub_call(engine, regexp, subject, replacement)
      when :hash_to_s
        value = Object.new
        value.define_singleton_method(:to_s) do
          notify.call(:value_to_s)
          "T"
        end
        gsub_call(engine, regexp, subject, { "a" => value })
      end
    end

    outcome =
      case mode
      when :normal
        { status: :returned, result: snapshot(operation.call) }
      when :error
        begin
          { status: :returned, result: snapshot(operation.call) }
        rescue CallbackError => e
          { status: :error, error_class: e.class.name, message: e.message }
        end
      when :throw
        token = Object.new
        result = catch(:capture_range_lifetime) { [token, operation.call] }
        if result.is_a?(Array) && result.first.equal?(token)
          { status: :returned, result: snapshot(result.last) }
        else
          { status: :throw, result: result }
        end
      when :resume
        fiber = Fiber.new { operation.call }
        first = fiber.resume
        GC.start(full_mark: true, immediate_sweep: true)
        GC.compact if GC.respond_to?(:compact)
        result = fiber.resume(:continued)
        { status: :resumed, first: first, result: snapshot(result) }
      end
    { outcome: outcome, events: events }
  end

  def scan_call(engine, regexp, subject, &block)
    return regexp.scan(subject, &block) if engine == :onibi

    subject.scan(regexp, &block)
  end

  def gsub_call(engine, regexp, subject, replacement = nil, &block)
    if engine == :onibi
      return regexp.gsub(subject, replacement, &block) unless replacement.nil?

      regexp.gsub(subject, &block)
    elsif replacement.nil?
      subject.gsub(regexp, &block)
    else
      subject.gsub(regexp, replacement, &block)
    end
  end

  def start_suspended_call(kind)
    subject = String.new("a")
    regexp = Onibi::Regexp.new("(a)")
    assert_native_route(regexp, subject)
    fiber = Fiber.new do
      case kind
      when :scan_block
        regexp.scan(subject) { Fiber.yield(:paused) }
      when :gsub_block
        regexp.gsub(subject) do
          Fiber.yield(:paused)
          "X"
        end
      when :hash_default
        regexp.gsub(subject, Hash.new do
          Fiber.yield(:paused)
          "D"
        end)
      when :hash_to_s
        value = Object.new
        value.define_singleton_method(:to_s) do
          Fiber.yield(:paused)
          "T"
        end
        regexp.gsub(subject, { "a" => value })
      end
    end
    assert_equal :paused, fiber.resume
    [fiber, subject, regexp]
  end

  def abandoned_call(kind)
    fiber, subject, _regexp = start_suspended_call(kind)
    [WeakRef.new(fiber), WeakRef.new(subject)]
  end

  def suspended_scan(pattern, subject)
    regexp = Onibi::Regexp.new(pattern)
    assert_native_route(regexp, subject)
    Fiber.new { regexp.scan(subject) { Fiber.yield(:paused) } }.tap do |fiber|
      assert_equal :paused, fiber.resume
    end
  end

  def external_enumerator(engine, kind, regexp, subject)
    owner = Object.new
    owner.define_singleton_method(:each) do |&consumer|
      if kind == :scan
        engine == :onibi ? regexp.scan(subject, &consumer) : subject.scan(regexp, &consumer)
      elsif engine == :onibi
        regexp.gsub(subject) do |value|
          consumer.call(value)
          "X"
        end
      else
        subject.gsub(regexp) do |value|
          consumer.call(value)
          "X"
        end
      end
    end
    owner.to_enum(:each)
  end

  def run_external_enumerator(engine, kind)
    regexp = engine_regexp(engine, "(a)")
    subject = String.new("aa")
    assert_native_route(regexp, subject) if engine == :onibi
    enumerator = external_enumerator(engine, kind, regexp, subject)
    first = snapshot(enumerator.next)
    GC.start(full_mark: true, immediate_sweep: true)
    GC.compact if GC.respond_to?(:compact)
    second = snapshot(enumerator.next)
    stopped = begin
      enumerator.next
    rescue StopIteration => e
      snapshot(e.result)
    end
    { first: first, second: second, stopped: stopped }
  end

  def abandoned_external_enumerator(engine, kind)
    regexp = engine_regexp(engine, "(a)")
    subject = String.new("aa")
    assert_native_route(regexp, subject) if engine == :onibi
    enumerator = external_enumerator(engine, kind, regexp, subject)
    enumerator.next
    [WeakRef.new(enumerator), WeakRef.new(subject)]
  end
end
