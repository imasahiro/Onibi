# frozen_string_literal: true

require_relative "../../test_helper"

class OnePassRegionLoweringTest < Minitest::Test
  def test_pipeline_records_one_pass_region_lowering
    ast = Onibi::Parser.new("abc").parse
    unit = Onibi::HybridAutomata::Optimization::Pipeline.default.call(
      ast, options: [], encoding: Encoding::UTF_8
    )

    assert_includes unit.applied_passes, :one_pass_region_lowering
    assert_equal 1, unit.cfg.blocks.length
  end
end
