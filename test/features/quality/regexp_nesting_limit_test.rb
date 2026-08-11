# frozen_string_literal: true

require_relative "../../test_helper"

class RegexpNestingLimitTest < Minitest::Test
  LIMIT = 256

  def test_pattern_nesting_limit_is_reported_before_recursive_parse
    assert_constructs(LIMIT - 1)
    assert_constructs(LIMIT)

    pattern = "#{"(" * (LIMIT + 1)}a#{")" * (LIMIT + 1)}"
    error = assert_raises(Onibi::RegexpError) { Onibi::Regexp.new(pattern) }
    assert_equal "regexp compilation limit exceeded: pattern_nesting", error.message
  end

  private

  def assert_constructs(depth)
    pattern = "#{"(" * depth}a#{")" * depth}"
    regexp = Onibi::Regexp.new(pattern)
    assert regexp.match?("a")
  rescue SystemStackError
    flunk "nesting depth #{depth} raised SystemStackError"
  end
end
