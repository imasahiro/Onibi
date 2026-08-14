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
  end

  def test_hfa_scan_returns_multiple_literal_captures
    assert_equal [%w[foo bar]], Onibi::Regexp.new("(?<first>foo)(?<second>bar)").scan("foobar")
  end
end
