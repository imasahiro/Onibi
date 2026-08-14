# frozen_string_literal: true

require_relative "../../test_helper"

class HfaBackendSurfaceTest < Minitest::Test
  def test_hfa_is_the_only_matcher_backend
    regexp = Onibi::Regexp.new("(a+)b")

    assert regexp.match?("aaab")
    assert_equal %w[aaab aaa], regexp.match("aaab").to_a
    refute defined?(Onibi::Codegen)
    refute(Onibi::Regexp.public_instance_methods(false).any? { |name| name.to_s.start_with?("codegen_") })
  end

  def test_cfg_optimization_namespace_remains_available_for_hfa_lowering
    ast = Onibi::Parser.new("a|ab").parse

    unit = Onibi::HybridAutomata::Optimization::Pipeline.default.call(
      ast, options: [], encoding: Encoding::UTF_8
    )

    assert(unit.cfg.blocks.any? { |block| block.terminator.opcode == :choice })
  end
end
