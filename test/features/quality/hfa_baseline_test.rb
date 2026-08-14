# frozen_string_literal: true

require "yaml"

require "test_helper"

class HfaBaselineTest < Minitest::Test
  MANIFEST_PATH = File.join(FIXTURES_ROOT, "codegen", "baseline.yml")

  def test_manifest_describes_the_hfa_public_matching_corpus
    manifest = YAML.load_file(MANIFEST_PATH)

    assert_equal 1, manifest.fetch("schema_version")
    assert_equal "hfa", manifest.fetch("engine")
    assert_equal expected_ast_nodes, manifest.fetch("ast_nodes").sort
    assert_equal %w[ascii8bit euc_jp utf8 windows_31j], manifest.fetch("encodings").sort
    refute manifest.to_s.match?(/codegen/i)
  end

  private

  def expected_ast_nodes
    Onibi::AST.constants(false).map(&:to_s).sort
  end
end
