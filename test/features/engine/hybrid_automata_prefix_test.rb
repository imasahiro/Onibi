# frozen_string_literal: true

require_relative "../../test_helper"

class HybridAutomataPrefixTest < Minitest::Test
  def test_large_prefix_hfa_uses_static_suffix_dfa
    program = Onibi::HybridAutomata.compile("BEGIN(?:ab|ac|ad|ba|bc|bd)+z")
    assert program.match?("xxBEGINabacadbabcbdxBEGINabacadbabcbdz")
    refute program.match?("xxBEGINabacadbabcbdxBEGINabacadbabcbdx")
    assert program.instance_variable_get(:@static_prefix_dfa_data)
  end

  def test_sparse_prefix_does_not_materialize_static_suffix_dfa
    program = Onibi::HybridAutomata.compile("BEGIN(?:ab|ac|ad|ba|bc|bd)+z")
    input = "#{"x" * 32_768}BEGINabacadbabcbdx"

    refute program.match?(input)
    assert_nil program.instance_variable_get(:@static_prefix_dfa_data)
  end

  def test_prefix_literal_candidate_preserves_match_span
    program = Onibi::HybridAutomata.compile("request_id=[0-9]+")

    assert_equal [6, 19, []], program.match_result("noise request_id=42", 0)
  end
end
