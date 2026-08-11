# frozen_string_literal: true

require "yaml"

require "test_helper"

class V1ApiInventoryTest < Minitest::Test
  INVENTORY_PATH = File.expand_path("../../fixtures/v1_api_inventory.yml", __dir__)
  BASELINE_PATH = File.expand_path("../../docs/v1-baseline.yml", __dir__)
  REQUIRED_ENTRY_KEYS = %w[aliases arguments block keywords kind name reason status target].freeze
  VALID_STATUSES = %w[supported partial unsupported excluded].freeze

  def setup
    @inventory = YAML.load_file(INVENTORY_PATH)
    @baseline = YAML.load_file(BASELINE_PATH)
  end

  def test_every_mri_public_api_entry_is_described_once
    entries = @inventory.fetch("entries")

    assert entries.is_a?(Array)
    assert_unique_entries(entries)
    entries.each { |entry| assert_inventory_entry(entry) }
    assert_mri_inventory
  end

  def test_inventory_records_aliases_and_exclusions
    entries = @inventory.fetch("entries")
    quote = entries.find { |entry| entry.fetch("target") == "Regexp" && entry.fetch("name") == "quote" }
    last_match = entries.find { |entry| entry.fetch("target") == "Regexp" && entry.fetch("name") == "last_match" }

    assert_equal ["escape"], quote.fetch("aliases")
    assert_equal "excluded", last_match.fetch("status")
    assert_match(/global match state/i, last_match.fetch("reason"))
  end

  def test_baseline_matches_the_selected_mri_runtime
    assert_equal "4.0.6", @baseline.fetch("ruby_version")
    assert_equal RUBY_VERSION, @baseline.fetch("ruby_version")
    assert_equal RUBY_REVISION.to_s, @baseline.fetch("ruby_revision").to_s
    assert_equal RUBY_ENGINE, @baseline.fetch("engine")
    assert_equal RUBY_PLATFORM, @baseline.fetch("platform")
    assert_equal "MRI", @baseline.fetch("implementation")
    assert_baseline_metadata
  end

  private

  def assert_unique_entries(entries)
    identities = entries.map { |entry| [entry.fetch("target"), entry.fetch("kind"), entry.fetch("name")] }

    assert_equal entries.length, identities.uniq.length
  end

  def assert_inventory_entry(entry)
    assert_entry_schema(entry)
    assert_entry_metadata(entry)
    assert_status_matches_onibi(entry)
  end

  def assert_entry_schema(entry)
    assert_equal REQUIRED_ENTRY_KEYS, entry.keys.sort
    assert_includes %w[Regexp MatchData], entry.fetch("target")
    assert_includes %w[class_method instance_method constant], entry.fetch("kind")
    assert_kind_of String, entry.fetch("name")
    assert_includes VALID_STATUSES, entry.fetch("status")
  end

  def assert_entry_metadata(entry)
    assert_kind_of Array, entry.fetch("arguments")
    assert_kind_of Array, entry.fetch("keywords")
    assert_kind_of Array, entry.fetch("aliases")
    assert_kind_of String, entry.fetch("reason")
    assert_includes [true, false], entry.fetch("block")
    assert_exclusion_reason(entry)
  end

  def assert_exclusion_reason(entry)
    return unless entry.fetch("status") == "excluded"

    refute_empty entry.fetch("reason")
  end

  def assert_mri_inventory
    assert_equal mri_methods("Regexp", :class_method), inventory_names("Regexp", "class_method")
    assert_equal mri_methods("Regexp", :instance_method), inventory_names("Regexp", "instance_method")
    assert_equal mri_constants("Regexp"), inventory_names("Regexp", "constant")
    assert_equal mri_methods("MatchData", :instance_method), inventory_names("MatchData", "instance_method")
  end

  def assert_baseline_metadata
    assert_match(/Ruby 4\.0\.6/, @baseline.fetch("description"))
    assert_operator @baseline.fetch("source_revision").length, :>=, 7
  end

  def inventory_names(target, kind)
    @inventory.fetch("entries").filter_map do |entry|
      entry.fetch("name") if entry.fetch("target") == target && entry.fetch("kind") == kind
    end.sort
  end

  def mri_methods(target, kind)
    klass = Object.const_get(target)
    methods = kind == :class_method ? klass.public_methods(false) : klass.public_instance_methods(false)
    methods.map(&:to_s).sort
  end

  def mri_constants(target)
    Object.const_get(target).constants(false).map(&:to_s).sort
  end

  def assert_status_matches_onibi(entry)
    status = entry.fetch("status")
    return if status == "excluded"

    supported = onibi_supports?(entry)
    message = "incorrect status for #{entry.fetch("target")}##{entry.fetch("name")}"

    assert_equal supported, status == "supported", message
  end

  def onibi_supports?(entry)
    case [entry.fetch("target"), entry.fetch("kind")]
    when %w[Regexp class_method]
      Onibi::Regexp.respond_to?(entry.fetch("name"))
    when %w[Regexp instance_method]
      Onibi::Regexp.new("a").respond_to?(entry.fetch("name"))
    when %w[Regexp constant]
      Onibi::Regexp.const_defined?(entry.fetch("name"), false)
    when %w[MatchData instance_method]
      Onibi::MatchData.new(nil, [], [[0, 0]]).respond_to?(entry.fetch("name"))
    end
  end
end
