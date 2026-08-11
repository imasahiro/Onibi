# frozen_string_literal: true

require "test_helper"

class MatchDataApiInventoryTest < Minitest::Test
  def test_instance_methods_match_ruby_4_0_6_inventory
    MatchData.instance_methods(false).sort.each do |method_name|
      assert_respond_to Onibi::MatchData.new(nil, [], [[0, 0]]), method_name
    end
  end
end
