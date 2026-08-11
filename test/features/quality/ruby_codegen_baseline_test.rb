# frozen_string_literal: true

require "yaml"

require "test_helper"

class RubyCodegenBaselineTest < Minitest::Test
  MANIFEST_PATH = File.join(FIXTURES_ROOT, "codegen", "baseline.yml")

  REQUIRED_SURFACES = %w[
    Onibi::Regexp#match
    Onibi::Regexp#match?
    Onibi::Regexp#=~
    Onibi::Regexp#===
    Onibi::Regexp#~
    Onibi::Regexp#scan
    Onibi::Regexp#gsub
  ].freeze

  REQUIRED_WORKLOADS = %w[
    literal_short
    literal_long_mismatch
    alternation_capture
    greedy_repetition
    assertion
    backreference
    unicode_casefold
    pathological_mismatch
  ].freeze

  def test_manifest_freezes_ast_public_surface_and_benchmark_scope
    manifest = YAML.load_file(MANIFEST_PATH)

    assert_equal 1, manifest.fetch("schema_version")
    assert_equal "4.0.6", manifest.fetch("ruby_version")
    assert_equal expected_ast_nodes, manifest.fetch("ast_nodes").sort
    assert_equal REQUIRED_SURFACES, manifest.fetch("public_surfaces")
    assert_equal REQUIRED_WORKLOADS, manifest.fetch("benchmark_workloads")
    assert_equal %w[ascii8bit euc_jp utf8 windows_31j], manifest.fetch("encodings").sort
  end

  # rubocop:disable Metrics/AbcSize
  def test_manifest_references_existing_core_fixture_corpus
    manifest = YAML.load_file(MANIFEST_PATH)
    fixture_path = File.expand_path(manifest.fetch("syntax_fixture"), PROJECT_ROOT)

    assert_path_exists fixture_path
    cases = YAML.load_file(fixture_path).fetch("cases")
    assert_kind_of Array, cases
    refute_empty cases
    cases.each do |fixture|
      assert fixture.key?("pattern"), fixture.inspect
      assert fixture.key?("input"), fixture.inspect
      assert fixture.key?("feature"), fixture.inspect
    end
  end
  # rubocop:enable Metrics/AbcSize

  private

  def expected_ast_nodes
    Onibi::AST.constants(false).map(&:to_s).sort
  end

  def assert_path_exists(path)
    assert File.file?(path), "expected fixture at #{path}"
  end
end
