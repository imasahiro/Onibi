# frozen_string_literal: true

require_relative "../../test_helper"

class CoverageConfigurationTest < Minitest::Test
  def test_simplecov_is_configured_for_the_test_suite
    assert_equal PROJECT_ROOT, SimpleCov.root
  end
end
