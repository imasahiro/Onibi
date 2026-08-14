# frozen_string_literal: true

require "yaml"

require "test_helper"

class HfaSemanticProbesTest < Minitest::Test
  PROBES_PATH = File.join(FIXTURES_ROOT, "codegen", "semantic_probes.yml")

  def test_hfa_matches_mri_for_high_risk_semantic_cases
    probes = YAML.load_file(PROBES_PATH)

    probes.each { |probe| assert_matches_mri(probe) }
  end

  private

  def assert_matches_mri(probe)
    pattern = probe.fetch("pattern")
    input = probe.fetch("input")
    options = probe.fetch("options", 0)
    position = probe.fetch("position", 0)
    expected = ::Regexp.new(pattern, options).match(input, position)
    actual = Onibi::Regexp.new(pattern, options).match(input, position)

    if expected.nil?
      assert_nil actual, probe.fetch("name")
      return
    end

    assert_equal expected.to_s, actual.to_s, probe.fetch("name")
    assert_equal expected.captures, actual.captures, probe.fetch("name")
    assert_equal expected && (0...expected.length).map { |index| expected.offset(index) },
                 actual && (0...actual.length).map { |index| actual.offset(index) }, probe.fetch("name")
  end
end
