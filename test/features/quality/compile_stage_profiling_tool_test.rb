# frozen_string_literal: true

require "open3"
require "test_helper"

class CompileStageProfilingToolTest < Minitest::Test
  SCRIPT = File.join(PROJECT_ROOT, "script", "profile_compile_stages.rb")

  def test_compile_stage_profiler_exposes_help
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, SCRIPT, "--help")

    assert_predicate status, :success?, stderr
    assert_includes stdout, "--feature"
    assert_includes stdout, "--iterations"
    assert_includes stdout, "--format"
  end

  def test_compile_stage_profiler_emits_stage_rows
    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby, SCRIPT, "--feature", "literals", "--iterations", "1", "--format", "tsv"
    )

    assert_predicate status, :success?, stderr
    assert_includes stdout, "label\tstage\titerations"
    assert_includes stdout, "literals/ascii/literal-search\tlexer"
    assert_includes stdout, "literals/ascii/literal-search\tsource_compile"
  end
end
