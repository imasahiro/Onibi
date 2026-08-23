# frozen_string_literal: true

require "test_helper"
require "yaml"
require_relative "../../../fuzz/fuzzer"

class V2CompilerCorpusTest < Minitest::Test
  def test_parser_fixture_and_fuzzer_patterns_reach_cfg_generation
    patterns = syntax_patterns + codegen_patterns + Fuzzer::PATTERNS

    patterns.uniq.each do |pattern|
      parsed = Onibi::Parser.parse(pattern)
      compiled = Onibi::Compiler.compile(parsed)

      assert_instance_of Onibi::CFG::Graph, compiled.graph, pattern
      assert_operator compiled.graph.blocks.length, :>=, 1, pattern
      assert compiled.graph.blocks.all?(&:terminator), pattern
    end
  end

  private

  def syntax_patterns
    cases = YAML.load_file(File.join(FIXTURES_ROOT, "syntax/core.yml")).fetch("cases")
    cases.reject { |fixture| fixture.fetch("outcome") == "error" }.map { |fixture| fixture.fetch("pattern") }
  end

  def codegen_patterns
    baseline = YAML.load_file(File.join(FIXTURES_ROOT, "codegen/baseline.yml"))
    probes = YAML.load_file(File.join(FIXTURES_ROOT, "codegen/semantic_probes.yml"))
    baseline.fetch("benchmark_cases").values.map { |entry| entry.fetch("pattern") } +
      probes.map { |entry| entry.fetch("pattern") }
  end
end
