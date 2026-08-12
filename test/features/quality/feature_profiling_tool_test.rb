# frozen_string_literal: true

require "open3"
require "test_helper"

class FeatureProfilingToolTest < Minitest::Test
  SCRIPT = File.join(PROJECT_ROOT, "script", "profile_regexp_features.rb")

  def test_feature_profile_tool_exposes_help
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, SCRIPT, "--help")

    assert_predicate status, :success?, stderr
    assert_includes stdout, "--engine"
    assert_includes stdout, "--operation"
    assert_includes stdout, "--format"
  end

  def test_feature_profile_tool_emits_one_machine_readable_case
    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby, SCRIPT, "--engine", "ruby", "--operation", "match",
      "--iterations", "1", "--feature", "literals", "--format", "tsv"
    )

    assert_predicate status, :success?, stderr
    assert_includes stdout, "label\toperation\titerations"
    assert_includes stdout, "literals/ascii/literal-search\tmatch"
  end
end
