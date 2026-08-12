# frozen_string_literal: true

require "open3"
require "test_helper"

class ScalingProfilingToolTest < Minitest::Test
  SCRIPT = File.join(PROJECT_ROOT, "script", "profile_regexp_scaling.rb")

  def test_scaling_profiler_exposes_help
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, SCRIPT, "--help")

    assert_predicate status, :success?, stderr
    assert_includes stdout, "--case"
    assert_includes stdout, "--sizes"
    assert_includes stdout, "--operation"
  end

  def test_scaling_profiler_emits_tsv
    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby, SCRIPT, "--engine", "ruby", "--case", "literal_miss",
      "--sizes", "16", "--iterations", "1", "--format", "tsv"
    )

    assert_predicate status, :success?, stderr
    assert_includes stdout, "case\tengine\toperation\tinput_size"
    assert_includes stdout, "literal_miss\truby\tmatch_question\t16"
  end
end
