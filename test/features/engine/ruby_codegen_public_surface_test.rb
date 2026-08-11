# frozen_string_literal: true

require_relative "../../test_helper"

class RubyCodegenPublicSurfaceTest < Minitest::Test
  def test_codegen_match_and_repeated_scan_surface
    regexp = Onibi::Regexp.new("a+")

    assert regexp.codegen_match?("aaa")
    assert_equal "aaa", regexp.codegen_match("aaa").to_s
    assert_equal %w[aaa a], regexp.codegen_scan("baaab a".delete(" ")).map(&:to_s)
  end
end
