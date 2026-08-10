# frozen_string_literal: true

require "test_helper"

class DfaSpecializationTest < Minitest::Test
  def test_specialization_is_lazy_and_preserves_public_results
    regexp = Onibi::Regexp.new("ab+")

    assert_nil regexp.instance_variable_get(:@dfa_specialization)
    before = regexp.match("xxabbb")
    refute_nil before
    refute_nil regexp.instance_variable_get(:@dfa_specialization)
    after = regexp.match("xxabbb")

    assert_equal before.to_a, after.to_a
    assert_equal before.begin(0), after.begin(0)
    assert_equal before.end(0), after.end(0)
  end
end
