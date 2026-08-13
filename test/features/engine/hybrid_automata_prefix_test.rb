# frozen_string_literal: true

require_relative "../../test_helper"

class HybridAutomataPrefixTest < Minitest::Test
  def test_large_prefix_hfa_uses_static_suffix_dfa
    program = Onibi::HybridAutomata.compile("BEGIN(?:ab|ac|ad|ba|bc|bd)+z")
    ruby = program.ruby_program
    assert_includes ruby.source, "STATIC_PREFIX_ROWS ="
    assert ruby.match?("xxBEGINabacadbabcbdz")
    refute ruby.match?("xxBEGINabacadbabcbdx")
  end

  def test_sparse_prefix_does_not_materialize_static_suffix_dfa
    program = Onibi::HybridAutomata.compile("BEGIN(?:ab|ac|ad|ba|bc|bd)+z")
    input = "#{"x" * 32_768}BEGINabacadbabcbdx"

    refute program.match?(input)
    assert_nil program.instance_variable_get(:@static_prefix_dfa_data)
  end
end
