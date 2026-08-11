# frozen_string_literal: true

require "test_helper"

class MrubyCiCacheTest < Minitest::Test
  WORKFLOW_PATH = File.join(PROJECT_ROOT, ".github", "workflows", "cross-runtime.yml")

  def test_mruby_job_caches_versioned_build_and_skips_build_on_cache_hit
    workflow = File.read(WORKFLOW_PATH)

    assert_includes workflow, "uses: actions/cache@v4"
    assert_includes workflow, "path: .mruby"
    assert_includes workflow,
                    "key: mruby-3.3.0-${{ runner.os }}-${{ hashFiles('.github/workflows/cross-runtime.yml') }}"
    assert_includes workflow, "id: mruby-cache"
    assert_includes workflow, "if: steps.mruby-cache.outputs.cache-hit != 'true'"
  end
end
