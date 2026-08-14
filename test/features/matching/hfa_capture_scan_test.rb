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
  end

  def test_hfa_scan_returns_multiple_literal_captures
    assert_equal [%w[foo bar]], Onibi::Regexp.new("(?<first>foo)(?<second>bar)").scan("foobar")
  end

  def test_hfa_scan_handles_nested_non_capture_groups_in_email_pattern
    pattern = "\\b(?<email>[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9-]+(?:\\.[A-Za-z0-9-]+)+)\\b"

    assert_equal [["user0@example.com"]], Onibi::Regexp.new(pattern).scan("Contact user0@example.com")
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
  end

  def test_hfa_uses_delimiter_search_for_negated_class_runs
    regexp = Onibi::Regexp.new("<[^>]*>")

    assert_equal ["<", ">", 0], regexp.send(:hfa_delimited_negated_class_result_spec)
    assert_equal ["<a>", "<b>"], regexp.scan("<a> <b>")
  end
end
