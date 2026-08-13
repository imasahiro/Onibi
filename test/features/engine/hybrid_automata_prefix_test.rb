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
end
