# frozen_string_literal: true

require_relative "../../test_helper"

class RubyCodegenCutoverTest < Minitest::Test
  def test_public_match_surfaces_can_switch_to_generated_program
    previous = Onibi::Regexp.codegen_default
    Onibi::Regexp.codegen_default = true
    regexp = Onibi::Regexp.new("(a)b")

    assert regexp.match?("ab")
    assert_equal ["ab", "a"], regexp.match("ab").to_a
  ensure
    Onibi::Regexp.codegen_default = previous
  end
end
