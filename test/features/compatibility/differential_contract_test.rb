# frozen_string_literal: true

require "yaml"

require "test_helper"
require_relative "../../support/differential_harness"

class DifferentialContractTest < Minitest::Test
  MATRIX = :api_differential
  INVENTORY = :api_inventory

  def setup
    @matrix = TestFixtures.load(MATRIX)
    @inventory = TestFixtures.load(INVENTORY)
  end

  def test_normalizes_match_metadata_and_records_error_call_sites
    assert_match_metadata(capture_fixture)
    assert_invalid_input(invalid_input_fixture)
  end

  def test_classifies_inventory_support_and_covers_every_inventory_target
    excluded = excluded_fixture

    assert_equal :unsupported_by_design, excluded.fetch(:support)
    assert_equal inventory_identities.sort_by(&:to_s), matrix_identities.sort_by(&:to_s)
    assert_equal error_categories, @matrix.fetch("error_categories").sort
  end

  private

  def capture_fixture
    DifferentialHarness.compare(
      id: "v1-capture-utf8",
      inventory: { target: "Regexp", kind: "instance_method", name: "match" },
      operation: :match, pattern: "(?<word>é+)", options: [], input: "café"
    )
  end

  def invalid_input_fixture
    DifferentialHarness.compare(
      id: "v1-invalid-input",
      inventory: { target: "Regexp", kind: "instance_method", name: "match" },
      operation: :match, pattern: "a", options: [], input: 1
    )
  end

  def excluded_fixture
    DifferentialHarness.compare(
      id: "v1-excluded-last-match",
      inventory: { target: "Regexp", kind: "class_method", name: "last_match", status: "excluded" },
      operation: :inventory, pattern: "a", options: [], input: "a"
    )
  end

  def assert_match_metadata(match)
    assert_equal "v1-capture-utf8", match.fetch(:id)
    assert match.fetch(:equal)
    assert_equal "UTF-8", match.fetch(:mri).fetch(:encoding)
    assert_equal "UTF-8", match.fetch(:onibi).fetch(:encoding)
    assert_equal ["é"], match.fetch(:mri).fetch(:captures)
    assert_equal [[3, 4], [3, 4]], match.fetch(:mri).fetch(:offsets)
  end

  def assert_invalid_input(invalid_input)
    assert_equal :invoke, invalid_input.fetch(:mri).fetch(:call_site)
    assert_equal :invoke, invalid_input.fetch(:onibi).fetch(:call_site)
    assert_equal "v1-invalid-input", invalid_input.fetch(:message).split(":", 2).first
  end

  def matrix_identities
    @matrix.fetch("fixtures").map { |fixture| fixture.fetch("inventory") }
  end

  def inventory_identities
    @inventory.fetch("entries").map do |entry|
      { "target" => entry.fetch("target"), "kind" => entry.fetch("kind"), "name" => entry.fetch("name") }
    end
  end

  def error_categories
    %w[encoding_error range_error syntax_error type_error]
  end
end
