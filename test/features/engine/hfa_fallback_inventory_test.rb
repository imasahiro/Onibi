# frozen_string_literal: true

require_relative "../../test_helper"

class HfaFallbackInventoryTest < Minitest::Test
  HFA_CASES = [
    ["(a*)\\1", "aaaa"],
    ["(?<x>a)(?i:\\k<x>)", "aA"],
    ["(?<x>.*)\\k<x>", "aa"],
    ["(?<x>a|ab)c\\g<x>d", "aacad"],
    ["(?<=[ß])x", "ßx"],
    ["(?~real)", "real"]
  ].freeze

  def test_known_fallback_shapes_are_now_hfa_only
    HFA_CASES.each do |pattern, input|
      assert_hfa_only(pattern, input, :match?)
      assert_hfa_only(pattern, input, :match)
      assert_hfa_only(pattern, input, :scan)
    end
  end

  private

  def assert_hfa_only(pattern, input, api)
    regexp = Onibi::Regexp.new(pattern)
    method = { match?: :codegen_match?, match: :codegen_match, scan: :codegen_each_result }.fetch(api)
    called = false
    original = regexp.method(method)
    regexp.define_singleton_method(method) do |*arguments, &block|
      called = true
      original.call(*arguments, &block)
    end

    api == :match? ? regexp.match?(input) : api == :match ? regexp.match(input) : regexp.scan(input)
    refute called, "expected #{pattern.inspect} #{api} to avoid codegen fallback"
  end
end
