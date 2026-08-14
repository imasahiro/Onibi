# frozen_string_literal: true

require_relative "../../test_helper"

class StateDominanceTest < Minitest::Test
  def test_cfg_publishes_block_dominators
    cfg = Onibi::HybridAutomata::CFG::Lowerer.new.call(Onibi::Parser.new("a|b").parse)

    assert_equal [cfg.entry], cfg.dominators.fetch(cfg.entry)
    cfg.blocks.each do |block|
      assert_includes cfg.dominators.fetch(block.id), cfg.entry
    end
  end
end
