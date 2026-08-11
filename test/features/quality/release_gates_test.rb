# frozen_string_literal: true

require "test_helper"
require "yaml"

class ReleaseGatesTest < Minitest::Test
  CHECKLIST_PATH = File.join(PROJECT_ROOT, "docs", "v1-release-checklist.yml")

  # rubocop:disable Metrics/AbcSize
  def test_release_checklist_requires_all_v1_gates_and_documents_workflow
    checklist = YAML.load_file(CHECKLIST_PATH)

    assert_equal 1, checklist.fetch("schema_version")
    assert_equal [
      "Ruby 4.0.6",
      "Cross-runtime",
      "RuboCop",
      "gem build",
      "clean gem install",
      "installed-gem smoke"
    ], checklist.fetch("required_statuses")
    assert_equal false, checklist.fetch("benchmarks").fetch("throughput_gate")
    assert_equal "squash", checklist.fetch("workflow").fetch("merge")
    assert_equal true, checklist.fetch("workflow").fetch("auto_merge")
    assert_equal "after_merge", checklist.fetch("workflow").fetch("tag")
  end
  # rubocop:enable Metrics/AbcSize

  def test_gemspec_has_no_runtime_extensions_or_external_regex_dependencies
    specification = Gem::Specification.load(File.join(PROJECT_ROOT, "onibi.gemspec"))

    assert_empty specification.runtime_dependencies
    assert_empty specification.extensions
    refute(specification.files.any? { |file| file.match?(/\.(?:c|cc|cpp|so)\z/) })
    refute(specification.files.any? { |file| file.match?(/ffi|oniguruma|onigmo/i) })
  end
end
