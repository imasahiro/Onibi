# frozen_string_literal: true

require "test_helper"

class AtomicGroupTest < Minitest::Test
  def test_atomic_group_does_not_backtrack_into_an_alternation
    regexp = Onibi::Regexp.new("(?>a|ab)c")

    assert_nil regexp.match("abc")
  end

  def test_atomic_group_keeps_the_first_successful_branch
    regexp = Onibi::Regexp.new("(?>a|ab)c")

    assert_equal "ac", regexp.match("ac")[0]
  end
end
