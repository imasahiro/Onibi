# frozen_string_literal: true

require "test_helper"
require "yaml"

class V1DocumentationTest < Minitest::Test
  INVENTORY_PATH = File.expand_path("../../fixtures/v1_api_inventory.yml", __dir__)
  REPORT_PATH = File.expand_path("../../docs/v1-compatibility-report.yml", __dir__)
  README_PATH = File.expand_path("../../README.md", __dir__)

  def test_compatibility_report_classifies_each_inventory_item_once
    inventory = YAML.safe_load(File.read(INVENTORY_PATH)).fetch("entries")
    report = YAML.safe_load(File.read(REPORT_PATH))
    source = File.expand_path(report.fetch("baseline").fetch("inventory_source"), File.dirname(REPORT_PATH))
    entries = YAML.safe_load(File.read(source)).fetch("entries")

    inventory_keys = inventory.map { |entry| inventory_key(entry) }.sort
    report_keys = entries.map { |entry| inventory_key(entry) }.sort

    assert_equal inventory_keys, report_keys
    counts = %w[supported partial excluded unsupported].to_h { |status| [status, 0] }
    inventory.each { |entry| counts[entry.fetch("status")] += 1 }
    assert_equal counts,
                 report.fetch("classification_counts")
    assert entries.all? { |entry| %w[supported partial excluded unsupported].include?(entry.fetch("status")) }
    refute_empty report.fetch("baseline").fetch("version")
    refute_empty report.fetch("baseline").fetch("source_revision")
  end

  def test_readme_documents_the_v1_usage_surfaces
    readme = File.read(README_PATH)

    %w[constructor matching MatchData scan gsub encoding timeout].each do |surface|
      assert_includes readme.downcase, surface.downcase
    end
    assert_includes readme, "Known MRI differences"
  end

  private

  def inventory_key(entry)
    [entry.fetch("target"), entry.fetch("kind"), entry.fetch("name")]
  end
end
