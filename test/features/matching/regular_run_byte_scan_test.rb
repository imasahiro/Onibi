# frozen_string_literal: true

require_relative "../../test_helper"

class RegularRunByteScanTest < Minitest::Test
  def test_regular_run_matches_disjoint_ascii_runs
    run = Onibi::Codegen::RegularRun.new(%w[a-z 0-9])

    assert_equal [0, 6, []], run.search("abc123!", 0, capture: true)
    assert_equal false, run.search("abcXYZ", 0, capture: false)
  end
end
