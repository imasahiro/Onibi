# frozen_string_literal: true

require "test_helper"

class RegexpApiInventoryTest < Minitest::Test
  CLASS_METHODS = %i[compile escape quote try_convert union linear_time? timeout timeout=].freeze
  INSTANCE_METHODS = %i[
    match match? =~ === ~ casefold? encoding fixed_encoding? options source names named_captures
    timeout to_s inspect == eql? hash
  ].freeze

  def test_supported_regexp_api_inventory_is_present
    CLASS_METHODS.each { |method| assert_respond_to Onibi::Regexp, method }
    INSTANCE_METHODS.each { |method| assert_respond_to Onibi::Regexp.new("a"), method }
  end

  def test_global_match_state_api_is_explicitly_excluded
    refute_respond_to Onibi::Regexp, :last_match
  end
end
