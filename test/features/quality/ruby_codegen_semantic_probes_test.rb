# frozen_string_literal: true

require "yaml"

require "test_helper"

class RubyCodegenSemanticProbesTest < Minitest::Test
  PROBES_PATH = File.join(FIXTURES_ROOT, "codegen", "semantic_probes.yml")

  REQUIRED_PROBES = %w[
    full_casefold_literal
    full_casefold_lookbehind
    positive_assertion_is_atomic
    subexpression_call_can_reenter
    g_origin_rejects_later_candidate
    g_origin_accepts_requested_position
    absence_stopper_prefix
    absence_stopper_capture
    absence_empty_stopper
  ].freeze

  def test_probe_manifest_contains_each_high_risk_semantic_case
    probes = YAML.load_file(PROBES_PATH)

    assert_equal REQUIRED_PROBES, probes.map { |probe| probe.fetch("name") }
    probes.each { |probe| assert_mri_observation(probe) }
  end

  private

  def assert_mri_observation(probe)
    regexp = Regexp.new(probe.fetch("pattern"), probe.fetch("options", 0))
    match = regexp.match(probe.fetch("input"), probe.fetch("position", 0))
    expected = probe.fetch("expected")

    if expected.fetch("match").nil?
      assert_nil match, probe.fetch("name")
    else
      assert_equal expected.fetch("match"), match.to_s, probe.fetch("name")
    end
    assert_equal expected.fetch("captures"), match&.captures, probe.fetch("name") unless match.nil?
    offsets = match && (0...match.length).map { |index| match.offset(index) }
    expected_offsets = expected.fetch("offsets")
    if expected_offsets.nil?
      assert_nil offsets, probe.fetch("name")
    else
      assert_equal expected_offsets, offsets, probe.fetch("name")
    end
  end
end
