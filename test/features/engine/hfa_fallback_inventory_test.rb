# frozen_string_literal: true

require_relative "../../test_helper"

class HfaFallbackInventoryTest < Minitest::Test
  FALLBACK_CASES = [
    ["(?<x>a)(?i:\\k<x>)", "aA"],
    ["(?<x>.*)\\k<x>", "aa"]
  ].freeze

  def test_known_fallbacks_still_use_codegen_until_tagged_hfa_support_lands
    FALLBACK_CASES.each do |pattern, input|
      assert_codegen_fallback(pattern, input, :match?)
      assert_codegen_fallback(pattern, input, :match)
      assert_codegen_fallback(pattern, input, :scan)
    end
  end

  private

  def assert_codegen_fallback(pattern, input, api)
    regexp = Onibi::Regexp.new(pattern)
    method = { match?: :codegen_match?, match: :codegen_match, scan: :codegen_each_result }.fetch(api)
    called = false
    original = regexp.method(method)
    regexp.define_singleton_method(method) do |*arguments, &block|
      called = true
      original.call(*arguments, &block)
    end

    api == :match? ? regexp.match?(input) : api == :match ? regexp.match(input) : regexp.scan(input)
    assert called, "expected #{pattern.inspect} #{api} to use its known codegen fallback"
  end
end
