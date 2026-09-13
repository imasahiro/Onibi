# frozen_string_literal: true

require "test_helper"

class MatchDataContractTest < Minitest::Test
  def test_supported_scan_uses_raw_captures_without_retained_mri_match
    native_match = ::Regexp.instance_method(:match)
    ::Regexp.define_method(:match) do |*|
      raise "supported Onibi match must not call MRI Regexp#match"
    end

    regexp = Onibi::Regexp.new("(?<letter>a)(b)?")

    assert_equal [["a", nil]], regexp.scan("a")
  ensure
    ::Regexp.define_method(:match, native_match) if native_match
  end

  def test_scan_capture_values_match_mri_for_supported_capture_shapes
    cases = [
      ["(a)(b)", "ab"],
      ["(?<x>a)(?<y>b)", "ab"],
      ["(?<x>a)(?<x>b)", "ab"],
      ["(?<x>a)?b", "b"],
      ["((a)?)", "a"],
      ["(a+)+", "aaa"],
      ["(?<x>é)", "é"],
      ["(a*)", "a"],
      ["(a)\\1", "aa"],
      ["(?=a)", "aa"]
    ]

    cases.each do |source, input|
      expected = input.scan(::Regexp.new(source))
      actual = Onibi::Regexp.new(source).scan(input)
      assert_equal expected, actual, source
    end
  end

  def test_scan_source_materializes_capture_values_from_raw_ranges
    source = File.read(File.join(PROJECT_ROOT, "ext/onibi/match.c"))
    scan = source[/static VALUE\nonibi_scan_body\(.*?\n}\n/m]

    refute_nil scan
    refute_match(/obj->regexp.*id_match/m, scan)
    assert_match(/ONIBI_EXEC_STATUS_FALLBACK.*id_scan/m, scan)
    assert_includes scan, "onibi_byte_slice(str, beg[i], end[i])"
  end

  def test_nested_repeated_unmatched_and_multibyte_captures_match_mri
    source = "(?<outer>(?<inner>é))(?<repeat>a)+(?<missing>b)?"
    input = "ééaa"
    expected = ::Regexp.new(source).match(input)
    actual = Onibi::Regexp.new(source).match(input)

    %i[to_a captures names named_captures pre_match post_match].each do |method|
      assert_equal expected.public_send(method), actual.public_send(method)
    end
    expected.length.times { |index| assert_equal expected.offset(index), actual.offset(index) }
  end

  def test_duplicate_named_captures_resolve_like_mri
    expected = /(?<word>a)(?<word>b)?/.match("a")
    actual = Onibi::Regexp.new("(?<word>a)(?<word>b)?").match("a")

    assert_equal expected.to_a, actual.to_a
    assert_equal expected.named_captures, actual.named_captures
    assert_equal expected["word"], actual["word"]
    assert_equal expected.inspect, actual.inspect
  end
end
