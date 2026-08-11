# frozen_string_literal: true

require_relative "../../test_helper"

class RubyCodegenCutoverTest < Minitest::Test
  def test_public_match_surfaces_use_the_generated_program
    regexp = Onibi::Regexp.new("(a)b")

    assert regexp.match?("ab")
    assert_equal ["ab", "a"], regexp.match("ab").to_a
    refute Onibi::Regexp.respond_to?(:codegen_default)
  end
end
