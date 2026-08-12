# frozen_string_literal: true

require_relative "../../test_helper"

class PredicateRegistryTest < Minitest::Test
  def test_repeated_predicate_keys_share_one_index
    registry = Onibi::Codegen::PredicateRegistry.new
    key = ["a-z", false]

    assert_equal 0, registry.register(key)
    assert_equal 0, registry.register(key)
    assert_equal [key], registry.entries
  end
end
