# frozen_string_literal: true

require "test_helper"
require "rbconfig"
require "timeout"

class GsubHashTest < Minitest::Test
  GC_LIFETIME_PROBE = <<~'RUBY'
    require "onibi"
    require "weakref"

    def weak_source_after_gsub(mode)
      length = mode.start_with?("abandoned") ? 10_000 : 1
      source = String.new("a" * length)
      weak = WeakRef.new(source)
      regexp = Onibi::Regexp.new("a")
      hash = nil
      enumerator = nil
      result = nil

      case mode
      when "normal"
        hash = Hash.new { "X" }
        result = regexp.gsub(source, hash)
        raise "wrong result" unless result == "X"
      when "exception"
        hash = Hash.new { raise "expected callback error" }
        begin
          regexp.gsub(source, hash)
        rescue RuntimeError => error
          raise unless error.message == "expected callback error"
        else
          raise "expected callback error"
        end
      when "throw"
        hash = Hash.new { throw(:gsub_lifetime, :thrown) }
        result = catch(:gsub_lifetime) { regexp.gsub(source, hash) }
        raise "wrong throw result" unless result == :thrown
      when "abandoned_block"
        enumerator = regexp.to_enum(:gsub, source)
        raise "wrong yielded match" unless enumerator.next == "a"
      when "abandoned_hash"
        hash = Hash.new { Fiber.yield(:paused); "X" }
        enumerator = regexp.to_enum(:gsub, source, hash)
        raise "wrong callback suspension" unless enumerator.next == :paused
      else
        raise "unknown mode"
      end

      result = nil
      hash = nil
      enumerator = nil
      source = nil
      regexp = nil
      weak
    end

    weak = weak_source_after_gsub(ARGV.fetch(0))
    10.times { GC.start(full_mark: true, immediate_sweep: true) }
    abort "subject remained alive" if weak.weakref_alive?
  RUBY

  def test_hash_values_use_mri_conversion_and_literal_append
    cases = [
      ["hit and miss", "aba", "a", ->(_input, _events) { { "a" => "X" } }],
      ["default value", "aba", "a", ->(_input, _events) { Hash.new("D") }],
      ["nil value", "a", "(a)", ->(_input, _events) { { "a" => nil } }],
      ["integer value", "a", "(a)", ->(_input, _events) { { "a" => 17 } }],
      ["literal escapes", "a", "(a)",
       ->(_input, _events) { { "a" => "\\1\\&\\k<word>" } }]
    ]

    cases.each do |label, subject, pattern, factory|
      assert_mri_equivalent(subject, pattern, factory, label: label)
    end

    counters = []
    object_factory = lambda do |_input, events|
      calls = [0]
      counters << calls
      value = Object.new
      value.define_singleton_method(:to_s) do
        calls[0] += 1
        events << [:value_to_s, calls[0]]
        "V#{calls[0]}"
      end
      { "a" => value }
    end
    assert_mri_equivalent("aa", "(a)", object_factory,
                          label: "to_s runs for each match")
    assert_equal [2, 2], counters.map(&:first)

    string_subclass_factory = lambda do |_input, events|
      klass = Class.new(String) do
        define_method(:to_s) do
          events << :string_subclass_to_s
          raise "String#to_s override must be bypassed"
        end
      end
      { "a" => klass.new("SUB") }
    end
    result = assert_mri_equivalent("a", "(a)", string_subclass_factory,
                                   label: "String subclass value")
    assert_empty result.first.fetch(:events)

    bad_texts = []
    bad_to_s_factory = lambda do |_input, events|
      value = Object.new
      bad_texts << Object.instance_method(:to_s).bind_call(value)
      value.define_singleton_method(:to_s) do
        events << :bad_to_s
        17
      end
      { "a" => value }
    end
    mri, onibi = observe_both("a", "(a)", bad_to_s_factory)
    assert_equal(mri.reject { |key, _value| key == :result },
                 onibi.reject { |key, _value| key == :result })
    [mri, onibi].zip(bad_texts).each do |observation, text|
      assert_match(/\A#<Object:0x[0-9a-f]+>\z/, text)
      assert_equal text, observation.dig(:result, :text)
      assert_equal text.bytes, observation.dig(:result, :bytes)
    end

    raising_factory = lambda do |_input, events|
      value = Object.new
      value.define_singleton_method(:to_s) do
        events << :to_s_raise
        raise "value conversion failed"
      end
      { "a" => value }
    end
    error = assert_mri_equivalent("a", "(a)", raising_factory,
                                  label: "raising to_s")
    assert_equal :error, error.first.fetch(:status)
    assert_equal "value conversion failed", error.first.fetch(:message)
  end

  def test_hash_uses_fresh_whole_match_keys
    whole_match_factory = lambda do |_input, _events|
      { "a" => "CAP-A", "b" => "CAP-B", "ab" => "WHOLE" }
    end
    result = assert_mri_equivalent("ab", "(a)(b)", whole_match_factory,
                                   label: "whole match selects key")
    assert_equal "WHOLE", result.first.dig(:result, :text)

    outcomes = []
    key_sets = []
    %i[mri onibi].each do |engine|
      keys = []
      factory = lambda do |input, events|
        Hash.new do |_hash, key|
          keys << key
          events << [:default_key, record_string(key), key.equal?(input),
                     key.frozen?]
          key << "!"
          "D"
        end
      end
      outcomes << observe_gsub(engine, "aa", "(a)", factory)
      key_sets << keys
    end

    assert_equal outcomes.first, outcomes.last
    key_sets.each do |keys|
      assert_equal 2, keys.length
      refute_same keys.first, keys.last
      assert_equal ["a!", "a!"], keys.map(&:to_s)
      assert keys.none?(&:frozen?)
      assert_equal [Encoding::UTF_8, Encoding::UTF_8], keys.map(&:encoding)
    end
    assert_equal "aa", outcomes.last.dig(:input, :text)

    zero_width_keys = []
    zero_width_factory = lambda do |_input, _events|
      Hash.new do |_hash, key|
        zero_width_keys << key
        "Z"
      end
    end
    result = assert_mri_equivalent("aa", "(?=a)", zero_width_factory,
                                   label: "zero-width keys")
    assert_equal "ZaZa", result.first.dig(:result, :text)
    assert_equal 4, zero_width_keys.length
    assert zero_width_keys.all?(&:empty?)
  end

  def test_hash_subclass_uses_native_lookup_and_default_behavior
    events = []
    klass = Class.new(Hash) do
      define_method(:to_hash) { raise "Hash#to_hash must be bypassed" }
      define_method(:[]) { |_key| raise "Hash#[] must be bypassed" }
      define_method(:default) do |key|
        events << [:default, key.bytes, key.encoding.name]
        "D"
      end
    end

    hit_factory = lambda do |_input, _events|
      hash = klass.new
      hash["a"] = "X"
      hash
    end
    hit = assert_mri_equivalent("a", "a", hit_factory,
                                label: "Hash subclass hit")
    assert_equal "X", hit.first.dig(:result, :text)

    default_factory = ->(_input, _observed_events) { klass.new }
    default = assert_mri_equivalent("a", "a", default_factory,
                                    label: "Hash subclass default")
    assert_equal "D", default.first.dig(:result, :text)
    assert_equal [[:default, [97], "UTF-8"], [:default, [97], "UTF-8"]], events
  end

  def test_to_hash_precedes_to_str_and_runs_before_matching
    precedence_factory = lambda do |_input, events|
      hash = { "a" => "HASH" }
      object = Object.new
      object.define_singleton_method(:to_hash) do
        events << :to_hash
        hash
      end
      object.define_singleton_method(:to_str) do
        events << :to_str
        "STRING"
      end
      object
    end
    result = assert_mri_equivalent("aa", "(a)", precedence_factory,
                                   label: "to_hash before to_str")
    assert_equal "HASHHASH", result.first.dig(:result, :text)
    assert_equal [:to_hash], result.first.fetch(:events)

    nil_factory = lambda do |_input, events|
      object = Object.new
      object.define_singleton_method(:to_hash) do
        events << :to_hash
        nil
      end
      object.define_singleton_method(:to_str) do
        events << :to_str
        "\\1"
      end
      object
    end
    nil_result = assert_mri_equivalent("a", "(a)", nil_factory,
                                       label: "nil to_hash then to_str")
    assert_equal "a", nil_result.first.dig(:result, :text)
    assert_equal %i[to_hash to_str], nil_result.first.fetch(:events)

    wrong_type_factory = lambda do |_input, events|
      object = Object.new
      object.define_singleton_method(:to_hash) do
        events << :to_hash
        []
      end
      object.define_singleton_method(:to_str) do
        events << :to_str
        "STRING"
      end
      object
    end
    wrong_type = assert_mri_equivalent("z", "a", wrong_type_factory,
                                       label: "bad to_hash return")
    assert_equal :error, wrong_type.first.fetch(:status)
    assert_match(/to_hash gives Array/, wrong_type.first.fetch(:message))
    assert_equal [:to_hash], wrong_type.first.fetch(:events)

    raising_factory = lambda do |_input, events|
      object = Object.new
      object.define_singleton_method(:to_hash) do
        events << :to_hash
        raise "to_hash failed"
      end
      object.define_singleton_method(:to_str) do
        events << :to_str
        "STRING"
      end
      object
    end
    raised = assert_mri_equivalent("z", "a", raising_factory,
                                   label: "raising to_hash")
    assert_equal "to_hash failed", raised.first.fetch(:message)
    assert_equal [:to_hash], raised.first.fetch(:events)

    string_subclass_factory = lambda do |_input, events|
      hash = { "a" => "HASH" }
      klass = Class.new(String)
      value = klass.new("\\1")
      value.define_singleton_method(:to_hash) do
        events << :to_hash
        hash
      end
      value.define_singleton_method(:to_str) do
        events << :to_str
        "STRING"
      end
      value
    end
    string_subclass = assert_mri_equivalent("a", "(a)",
                                            string_subclass_factory,
                                            label: "String subclass to_hash")
    assert_equal "HASH", string_subclass.first.dig(:result, :text)
    assert_equal [:to_hash], string_subclass.first.fetch(:events)

    no_match_factory = lambda do |_input, events|
      hash = Hash.new do |_receiver, _key|
        events << :lookup
        "D"
      end
      object = Object.new
      object.define_singleton_method(:to_hash) do
        events << :to_hash
        hash
      end
      object
    end
    no_match = assert_mri_equivalent("z", "a", no_match_factory,
                                     label: "coerce before no match")
    assert_equal "z", no_match.first.dig(:result, :text)
    assert_equal [:to_hash], no_match.first.fetch(:events)
  end

  def test_hash_replacement_ignores_a_supplied_block
    factory = ->(_input, _events) { { "a" => "X" } }
    result = assert_mri_equivalent("aba", "a", factory, with_block: true,
                                                        label: "explicit Hash ignores block")
    assert_equal "XbX", result.first.dig(:result, :text)
    assert_empty result.first.fetch(:yielded)
  end

  def test_to_hash_subject_mutation_precedes_the_length_snapshot
    factory = lambda do |input, events|
      hash = { "ax" => "R" }
      object = Object.new
      object.define_singleton_method(:to_hash) do
        events << :to_hash
        input << "x"
        hash
      end
      object
    end
    result = assert_mri_equivalent("a", "ax", factory,
                                   label: "to_hash grows subject")
    assert_equal "R", result.first.dig(:result, :text)
    assert_equal "ax", result.first.dig(:input, :text)
  end

  def test_hash_changes_between_matches_are_visible
    factory = lambda do |_input, events|
      calls = 0
      Hash.new do |hash, _key|
        calls += 1
        events << [:default, calls]
        hash["x"] = "MUT" if calls == 1
        "D#{calls}"
      end
    end
    result = assert_mri_equivalent("abx", ".", factory,
                                   label: "Hash mutation between matches")
    assert_equal "D1D2MUT", result.first.dig(:result, :text)
    assert_equal [[:default, 1], [:default, 2]], result.first.fetch(:events)
  end

  def test_same_length_subject_mutations_match_mri
    byte_mutation = lambda do |input, _events|
      Hash.new do |_hash, _key|
        input.setbyte(0, "z".ord)
        "D"
      end
    end
    assert_mri_equivalent("aa", "a", byte_mutation,
                          label: "same-length byte mutation")

    encoding_mutation = lambda do |input, events|
      calls = 0
      Hash.new do |_hash, key|
        events << [:key_encoding, key.encoding.name]
        calls += 1
        input.force_encoding(Encoding::BINARY) if calls == 1
        "D"
      end
    end
    result = assert_mri_equivalent("aa", "a", encoding_mutation,
                                   label: "same-length encoding mutation")
    assert_equal [[:key_encoding, "UTF-8"], [:key_encoding, "ASCII-8BIT"]],
                 result.first.fetch(:events)
  end

  def test_subject_length_checks_follow_lookup_and_value_conversion
    default_mutation = lambda do |input, _events|
      Hash.new do |_hash, _key|
        input << "x"
        "D"
      end
    end
    mutated = assert_mri_equivalent("a", "a", default_mutation,
                                    label: "default proc grows subject")
    assert_equal "string modified", mutated.first.fetch(:message)

    conversion_modes = %i[raise restore return]
    conversion_modes.each do |mode|
      factory = lambda do |input, events|
        value = Object.new
        value.define_singleton_method(:to_s) do
          events << [:to_s, mode]
          if mode == :raise
            raise "value conversion wins"
          elsif mode == :restore
            input.replace("a")
          else
            input << "x"
          end

          "X"
        end
        Hash.new do |_hash, _key|
          input << "x"
          value
        end
      end
      result = assert_mri_equivalent("a", "a", factory,
                                     label: "lookup then value conversion #{mode}")
      if mode == :raise
        assert_equal "value conversion wins", result.first.fetch(:message)
      elsif mode == :restore
        assert_equal :ok, result.first.fetch(:status)
        assert_equal "X", result.first.dig(:result, :text)
      else
        assert_equal "string modified", result.first.fetch(:message)
      end
    end
  end

  def test_hash_value_encodings_match_mri
    windows_value = lambda do |_input, _events|
      { "あ" => "表".encode("Windows-31J") }
    end
    result = assert_mri_equivalent("xあy", "(あ)", windows_value,
                                   label: "Windows-31J value")
    assert_equal "Windows-31J", result.first.dig(:result, :encoding)

    binary_value = lambda do |_input, _events|
      { "a" => [255].pack("C*").force_encoding(Encoding::BINARY) }
    end
    assert_mri_equivalent("a", "(a)", binary_value,
                          label: "binary value")

    no_match = lambda do |_input, _events|
      { "あ".encode("Windows-31J") => "表".encode("Windows-31J") }
    end
    result = assert_mri_equivalent("xyz", "あ", no_match,
                                   label: "no match keeps source encoding")
    assert_equal "UTF-8", result.first.dig(:result, :encoding)
  end

  def test_hash_callback_throw_and_error_recovery
    raising = ->(_input, _events) { Hash.new { raise "default failed" } }
    error = assert_mri_equivalent("a", "a", raising,
                                  label: "default proc raises")
    assert_equal "default failed", error.first.fetch(:message)

    throwing = lambda do |_input, _events|
      Hash.new { throw :hash_replacement_throw, %i[throw default_proc_throw] }
    end
    thrown = assert_mri_equivalent("a", "a", throwing,
                                   label: "default proc throws")
    assert_equal :throw, thrown.first.fetch(:status)
    assert_equal :default_proc_throw, thrown.first.fetch(:thrown)

    assert_equal "X", Onibi::Regexp.new("a").gsub("a", "a" => "X")
  end

  def test_nested_native_calls_and_small_gc_stress
    events = []
    hash = Hash.new do |_receiver, _key|
      nested = Onibi::Regexp.new("x").match("x")
      events << [:nested, nested[0]]
      "D"
    end
    result = Onibi::Regexp.new("(a)").gsub("a", hash)
    assert_equal "D", result
    assert_equal [[:nested, "x"]], events

    old_stress = GC.stress
    begin
      GC.stress = true
      value_hash = Hash.new do |_receiver, _key|
        value = Object.new
        value.define_singleton_method(:to_s) { "GC" }
        value
      end
      assert_equal "GC", Onibi::Regexp.new("a").gsub("a", value_hash)
    ensure
      GC.stress = old_stress
    end
  end

  def test_suspended_hash_and_block_callbacks_resume_after_compaction
    events = []
    value = Object.new
    value.define_singleton_method(:to_s) do
      events << :value_to_s
      Fiber.yield(:hash_value_to_s)
      String.new("VV")
    end
    hash = Hash.new do |_receiver, key|
      events << [:default, key.dup]
      Fiber.yield(:hash_default)
      value
    end
    hash_enum = Onibi::Regexp.new("a").to_enum(:gsub, String.new("a"), hash)

    assert_equal :hash_default, hash_enum.next
    GC.start(full_mark: true, immediate_sweep: true)
    GC.compact
    assert_equal [:default, "a"], events.fetch(0)
    assert_equal :hash_value_to_s, hash_enum.next
    GC.start(full_mark: true, immediate_sweep: true)
    GC.compact
    assert_equal [:value_to_s], events.drop(1)
    old_stress = GC.stress
    begin
      GC.stress = true
      completed = assert_raises(StopIteration) { hash_enum.next }
    ensure
      GC.stress = old_stress
    end
    assert_equal "VV", completed.result

    block_enum = Onibi::Regexp.new("a").to_enum(:gsub, String.new("aa"))
    assert_equal "a", block_enum.next
    GC.start(full_mark: true, immediate_sweep: true)
    GC.compact
    assert_equal "a", block_enum.next
    GC.start(full_mark: true, immediate_sweep: true)
    GC.compact
    completed = assert_raises(StopIteration) { block_enum.next }
    assert_equal "", completed.result
  end

  def test_gsub_releases_subject_after_normal_exception_throw_and_abandonment
    %w[normal exception throw abandoned_block abandoned_hash].each do |mode|
      assert_child_collects_subject(mode)
    end
  end

  def test_hash_fallback_does_not_repeat_to_hash_conversion
    hash_factory = ->(_input, _events) { { "é" => "R" } }
    assert_mri_equivalent("é", "\\X", hash_factory,
                          label: "fallback Hash replacement")
    result = observe_onibi_fallback(hash_factory)
    assert_equal "R", result.fetch(:result).fetch(:text)
    assert_equal 1, result.fetch(:string_gsub_calls)

    conversions = 0
    to_hash_factory = lambda do |_input, events|
      object = Object.new
      object.define_singleton_method(:to_hash) do
        conversions += 1
        events << :to_hash
        { "é" => "R" }
      end
      object
    end
    assert_mri_equivalent("é", "\\X", to_hash_factory,
                          label: "fallback to_hash replacement")
    conversions = 0
    result = observe_onibi_fallback(to_hash_factory)
    assert_equal "R", result.fetch(:result).fetch(:text)
    assert_equal 1, result.fetch(:string_gsub_calls)
    assert_equal 1, conversions
    assert_equal [:to_hash], result.fetch(:events)
  end

  private

  def assert_child_collects_subject(mode)
    command = [RbConfig.ruby, "-I#{PROJECT_ROOT}/lib",
               "-I#{PROJECT_ROOT}/ext/onibi", "-e", GC_LIFETIME_PROBE, mode]
    pid = Process.spawn(
      *command,
      chdir: PROJECT_ROOT,
      out: File::NULL,
      err: File::NULL
    )
    status = Timeout.timeout(5) { Process.waitpid2(pid).last }
    assert_predicate status, :success?, "GC lifetime probe failed for #{mode}"
  rescue Timeout::Error
    begin
      Process.kill("KILL", pid)
    rescue Errno::ESRCH
      nil
    end
    begin
      Process.waitpid(pid)
    rescue Errno::ECHILD
      nil
    end
    flunk "GC lifetime probe timed out for #{mode}"
  end

  def assert_mri_equivalent(subject, pattern, replacement_factory, with_block: false,
                            label: nil)
    mri, onibi = observe_both(subject, pattern, replacement_factory,
                              with_block: with_block)
    assert_equal mri, onibi, label
    [mri, onibi]
  end

  def observe_both(subject, pattern, replacement_factory, with_block: false)
    %i[mri onibi].map do |engine|
      observe_gsub(engine, subject, pattern, replacement_factory,
                   with_block: with_block)
    end
  end

  def observe_gsub(engine, subject, pattern, replacement_factory,
                   with_block: false)
    input = subject.dup
    events = []
    yielded = []
    replacement = replacement_factory.call(input, events)
    regexp = engine == :mri ? ::Regexp.new(pattern) : Onibi::Regexp.new(pattern)
    outcome = catch(:hash_replacement_throw) do
      result = if with_block
                 gsub_with_block(engine, input, regexp, replacement,
                                 events, yielded)
               elsif engine == :mri
                 input.gsub(regexp, replacement)
               else
                 regexp.gsub(input, replacement)
               end
      [:ok, result]
    rescue StandardError => e
      [:error, e.class.name, e.message]
    end

    observation = {
      status: outcome.fetch(0),
      input: record_string(input),
      events: events,
      yielded: yielded
    }
    case outcome.fetch(0)
    when :ok
      observation[:result] = record_string(outcome.fetch(1))
    when :error
      observation[:exception_class] = outcome.fetch(1)
      observation[:message] = outcome.fetch(2)
    else
      observation[:thrown] = outcome.fetch(1)
    end
    observation
  end

  def gsub_with_block(engine, input, regexp, replacement, events, yielded)
    block = lambda do |match|
      yielded << record_string(match)
      events << :ignored_block_yield
      "BLOCK"
    end
    if engine == :mri
      input.gsub(regexp, replacement, &block)
    else
      regexp.gsub(input, replacement, &block)
    end
  end

  def observe_onibi_fallback(replacement_factory)
    input = "é".dup
    events = []
    replacement = replacement_factory.call(input, events)
    regexp = Onibi::Regexp.new("\\X")
    diagnostics = regexp.send(:__onibi_diagnostics__, input.dup)
    string_gsub_calls = 0
    trace = TracePoint.new(:c_call) do |event|
      string_gsub_calls += 1 if event.method_id == :gsub &&
                                event.defined_class == String
    end
    begin
      result = trace.enable { regexp.gsub(input, replacement) }
    ensure
      trace.disable if trace.enabled?
    end
    assert_equal 1, diagnostics.fetch(:fallback)
    {
      result: record_string(result),
      events: events,
      string_gsub_calls: string_gsub_calls
    }
  end

  def record_string(value)
    text = value.dup.force_encoding(Encoding::UTF_8)
    {
      text: text.valid_encoding? ? text : nil,
      bytes: value.bytes,
      encoding: value.encoding.name,
      class: value.class.name || "anonymous",
      frozen: value.frozen?
    }
  end
end
