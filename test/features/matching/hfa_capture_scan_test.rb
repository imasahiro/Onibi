# frozen_string_literal: true

require "test_helper"

class HfaCaptureScanTest < Minitest::Test
  ACCESS_LOG_PATTERN = <<~'PATTERN'.strip
    (?<ip>[0-9A-Fa-f:.]+) - - \[(?<timestamp>[^\]]+)\] "(?<method>[A-Z]+) (?<uri>[^ ]+) HTTP/[0-9.]+" (?<status>[0-9]{3}) (?<bytes>[0-9-]+)
  PATTERN
  ACCESS_LOG = '192.0.2.1 - - [10/Aug/2026:12:00:00 +0000] "GET /api/v1/users/0?page=1&active=true HTTP/1.1" 200 17049'

  def test_hfa_scan_returns_capture_values_for_access_log_shape
    regexp = Onibi::Regexp.new(ACCESS_LOG_PATTERN)

    assert_equal [["192.0.2.1", "10/Aug/2026:12:00:00 +0000", "GET",
                   "/api/v1/users/0?page=1&active=true", "200", "17049"]], regexp.scan(ACCESS_LOG)
    assert regexp.send(:hfa_top_level_capture_plan)
    assert regexp.send(:hfa_reverse_literal_capture_spec)
    result = regexp.send(:hfa_program).match_result(ACCESS_LOG, 0)
    assert_equal [[0, 9], [15, 41], [44, 47], [48, 82], [93, 96], [97, 102]],
                 regexp.send(:hfa_top_level_capture_offsets, ACCESS_LOG, result[0], result[1])
  end

  def test_hfa_scan_returns_multiple_literal_captures
    assert_equal [%w[foo bar]], Onibi::Regexp.new("(?<first>foo)(?<second>bar)").scan("foobar")
  end

  def test_hfa_capture_boundary_respects_class_values_that_include_delimiter
    assert_equal [["a,b"]], Onibi::Regexp.new("(?<value>[a-z,]+),").scan("a,b,")
  end

  def test_hfa_scan_handles_nested_non_capture_groups_in_email_pattern
    pattern = "\\b(?<email>[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9-]+(?:\\.[A-Za-z0-9-]+)+)\\b"

    regexp = Onibi::Regexp.new(pattern)

    assert regexp.send(:hfa_reverse_literal_capture_spec)
    assert_equal [["user0@example.com"]], regexp.scan("Contact user0@example.com")
    assert_equal [["foo@example.com"]], regexp.scan(".foo@example.com")
  end

  def test_hfa_scan_handles_capture_prefix_url_pattern
    pattern = "(?<url>https?://[A-Za-z0-9.-]+(?:/[A-Za-z0-9._~/?=&%-]+)?)"

    assert_equal [["https://example.com/docs/0?lang=en."]],
                 Onibi::Regexp.new(pattern).scan("See https://example.com/docs/0?lang=en.")
  end

  def test_hfa_extracts_literal_prefix_inside_capturing_group
    pattern = "(?<url>https?://[A-Za-z0-9.-]+)"
    regexp = Onibi::Regexp.new(pattern)

    assert_equal "http", regexp.send(:hfa_program).prefix_literal
  end

  def test_hfa_uses_whole_match_capture_for_wrapped_capture
    pattern = "\\b(?<email>[A-Za-z]+@[A-Za-z]+)\\b"
    regexp = Onibi::Regexp.new(pattern)

    assert_equal [["user@example"]], regexp.scan("Contact user@example")
    assert_equal [[0, 12]], regexp.send(:hfa_whole_capture_offsets, 0, 12)
    assert_same regexp.send(:hfa_whole_capture_group), regexp.send(:hfa_whole_capture_group)
  end

  def test_hfa_scan_handles_structured_log_prefix_pattern
    pattern = "request_id=(?<request_id>[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-" \
              "[0-9a-f]{4}-[0-9a-f]{12}) timestamp=(?<timestamp>[0-9T:-]+Z)"
    input = "request_id=00000000-0000-4000-8000-000000000000 timestamp=2026-08-10T00:00:00Z"

    assert_equal [["00000000-0000-4000-8000-000000000000", "2026-08-10T00:00:00Z"]],
                 Onibi::Regexp.new(pattern).scan(input)
    assert Onibi::Regexp.new(pattern).send(:hfa_top_level_capture_scan_spec)
  end

  def test_hfa_scan_uses_alternative_prefixes_for_top_level_capture
    pattern = "(?<identifier>v[0-9]+\\.[0-9]+|api/[a-z]+/[0-9]+|pkg-[a-z0-9-]+)"
    regexp = Onibi::Regexp.new(pattern)

    assert_equal [%w[v1.2], %w[api/users/42], %w[pkg-client]], regexp.scan("v1.2 api/users/42 pkg-client")
    assert_equal %w[v api/ pkg-], regexp.send(:hfa_top_level_capture_scan_spec)
  end

  def test_hfa_uses_delimiter_search_for_negated_class_runs
    regexp = Onibi::Regexp.new("<[^>]*>")

    assert_equal ["<", ">", 0], regexp.send(:hfa_delimited_negated_class_result_spec)
    assert_equal ["<a>", "<b>"], regexp.scan("<a> <b>")
  end

  def test_hfa_scans_literal_and_class_sequences_without_nfa_transitions
    regexp = Onibi::Regexp.new("tHa[Nt]")

    assert regexp.send(:hfa_literal_class_scan_spec)
    assert_equal %w[tHaN tHat], regexp.scan("x tHaN tHat")
  end
end
