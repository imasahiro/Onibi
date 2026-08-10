# frozen_string_literal: true

require "test_helper"

class CaseFoldingTest < Minitest::Test
  def test_ignorecase_matches_unicode_simple_case_folding
    assert Onibi::Regexp.new("k", ["ignorecase"]).match?("K")
  end
end
