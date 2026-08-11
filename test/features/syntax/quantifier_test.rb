# frozen_string_literal: true

require "test_helper"

class QuantifierTest < Minitest::Test
  def test_core_quantifiers_match_empty_and_repeated_input
    assert Onibi::Regexp.new("a?").match?("bbb")
    assert Onibi::Regexp.new("a+").match?("bbbba")
    assert Onibi::Regexp.new("a{2}").match?("caa")
    assert Onibi::Regexp.new("a{2,4}").match?("caaa")
    refute Onibi::Regexp.new("a{2,4}").match?("ca")
  end
end
