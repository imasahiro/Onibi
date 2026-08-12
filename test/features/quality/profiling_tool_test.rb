# frozen_string_literal: true

require "open3"
require "test_helper"

class ProfilingToolTest < Minitest::Test
  SCRIPT = File.join(PROJECT_ROOT, "script", "profile_regex_redux.rb")

  def test_profile_tool_exposes_help
    stdout, stderr, status = Open3.capture3(ruby_command, SCRIPT, "--help")

    assert_predicate status, :success?, stderr
    assert_includes stdout, "--engine"
    assert_includes stdout, "--profile"
    assert_includes stdout, "--yjit"
    assert_includes stdout, "--breakdown"
  end

  def test_profile_tool_can_emit_a_warm_operation_breakdown
    stdout, stderr, status = Open3.capture3(
      ruby_command, SCRIPT, "--engine", "ruby", "--phase", "warm_match",
      "--iterations", "1", "--warmup", "0", "--profile", "none", "--breakdown"
    )

    assert_predicate status, :success?, stderr
    assert_includes stdout, "## Operation breakdown"
    assert_includes stdout, "remove_breaks"
  end

  private

  def ruby_command
    RbConfig.ruby
  end
end
