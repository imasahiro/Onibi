# frozen_string_literal: true

require "test_helper"

class CaseFoldingTest < Minitest::Test
  def test_ignorecase_matches_unicode_simple_case_folding
    assert Onibi::Regexp.new("k", ["ignorecase"]).match?("K")
  end

  def test_ignorecase_matches_unicode_full_case_folding
    assert Onibi::Regexp.new("ß", ["ignorecase"]).match?("SS")
  end
end
