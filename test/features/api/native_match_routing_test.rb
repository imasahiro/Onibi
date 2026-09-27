# frozen_string_literal: true

require "test_helper"

class NativeMatchRoutingTest < Minitest::Test
  def with_mri_match_guard
    native_match = ::Regexp.instance_method(:match)
    ::Regexp.define_method(:match) do |*|
      raise "supported Onibi match must not call MRI Regexp#match"
    end
    yield
  ensure
    ::Regexp.define_method(:match, native_match) if native_match
  end

  def test_supported_match_builds_onibi_match_data_from_native_registers
    regexp = Onibi::Regexp.new("(?<letter>a)(?<tail>b)?")
    /prior/.match("prior")
    before = ::Regexp.last_match

    match = with_mri_match_guard { regexp.match("a") }

    assert_instance_of Onibi::MatchData, match
    assert_equal ["a", "a", nil], match.to_a
    assert_same regexp, match.regexp
    assert_equal [[0, 1], [0, 1], [-1, -1]],
                 match.send(:__onibi_match_data_diagnostics__)[:raw_registers]
    assert_same before, ::Regexp.last_match
    assert_equal ["prior"], Onibi::Regexp.last_match.to_a
  end

  def test_supported_match_block_receives_onibi_match_data
    regexp = Onibi::Regexp.new("a")
    /prior/.match("prior")
    before = ::Regexp.last_match

    result = with_mri_match_guard do
      regexp.match("ba") { |match| [match.class, match[0], match.begin(0)] }
    end

    assert_equal [Onibi::MatchData, "a", 1], result
    assert_same before, ::Regexp.last_match
  end

  def test_unsupported_pattern_keeps_mri_fallback
    regexp = Onibi::Regexp.new("\\X")

    match = regexp.match("a")

    assert_instance_of ::MatchData, match
    assert_equal ["a"], match.to_a
  end

  def test_native_routing_uses_ensured_heap_register_storage
    root = File.expand_path("../../..", __dir__)
    source = File.read(File.join(root, "ext", "onibi", "rseq.c"))
    routing = source[/static VALUE\nonibi_match\(.*?\n}\n\nstatic VALUE\nonibi_match_p/m]
    ensure_body = source[/static VALUE\nonibi_match_ensure\(.*?\n}\n/m]

    refute_nil routing
    refute_nil ensure_body
    assert_includes routing, "ruby_xmalloc"
    assert_includes routing, "rb_ensure(onibi_match_body"
    refute_includes routing, "ALLOCA_N"
    assert_includes ensure_body, "ruby_xfree(call->ranges)"
  end
end
