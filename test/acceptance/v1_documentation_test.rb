# frozen_string_literal: true

require "test_helper"
require "yaml"

class V1DocumentationTest < Minitest::Test
  INVENTORY_PATH = File.expand_path("../../fixtures/v1_api_inventory.yml", __dir__)
  REPORT_PATH = File.expand_path("../../docs/v1-compatibility-report.yml", __dir__)
  README_PATH = File.expand_path("../../README.md", __dir__)

  def test_compatibility_report_classifies_each_inventory_item_once
    inventory = load_inventory
    report = YAML.safe_load(File.read(REPORT_PATH))
    entries = load_report_inventory(report)

    assert_equal inventory_keys(inventory), inventory_keys(entries)
    assert_equal status_counts(inventory), report.fetch("classification_counts")
    assert_valid_statuses(entries)
    assert_baseline(report)
  end

  def test_readme_documents_the_v1_usage_surfaces
    readme = File.read(README_PATH)

    %w[constructor matching MatchData scan gsub encoding timeout].each do |surface|
      assert_includes readme.downcase, surface.downcase
    end
    assert_includes readme, "Known MRI differences"
  end

  private

  def load_inventory
    YAML.safe_load(File.read(INVENTORY_PATH)).fetch("entries")
  end

  def load_report_inventory(report)
    source = File.expand_path(report.fetch("baseline").fetch("inventory_source"), File.dirname(REPORT_PATH))
    YAML.safe_load(File.read(source)).fetch("entries")
  end

  def inventory_keys(entries)
    entries.map { |entry| inventory_key(entry) }.sort
  end

  def status_counts(entries)
    counts = %w[supported partial excluded unsupported].to_h { |status| [status, 0] }
    entries.each { |entry| counts[entry.fetch("status")] += 1 }
    counts
  end

  def assert_valid_statuses(entries)
    statuses = %w[supported partial excluded unsupported]
    assert(entries.all? { |entry| statuses.include?(entry.fetch("status")) })
  end

  def assert_baseline(report)
    refute_empty report.fetch("baseline").fetch("version")
    refute_empty report.fetch("baseline").fetch("source_revision")
  end

  def inventory_key(entry)
    [entry.fetch("target"), entry.fetch("kind"), entry.fetch("name")]
  end
end
