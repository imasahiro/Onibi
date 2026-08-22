# frozen_string_literal: true

require "test_helper"
require "yaml"
require_relative "../../../fuzz/fuzzer"

class V2ParserCorpusTest < Minitest::Test
  V1_PATTERNS = [
    "a", "ab", "a|b", "cat|dog|fox", "a(b|c)d+", "(?:ab|ac)+z", "(?>a|ab)b",
    "(a)(b)?", "(?<word>[a-z]+)", "(?<animal>cat)(dog)", "(?<outer>(?<inner>ab)+)c",
    "a?", "a*", "a+", "a+?", "a??", "a++", "a{2}", "a{2,}", "a{2,4}",
    "a{1,3}+a", "[abc]", "[^a]", "[a-z]", "[a-z[0-9]]", "[a-w&&[^c-g]z]",
    "[[:digit:]]+", "[[:word:]]+", "[\\-\\]]", "[\\cA\\C-B]", "[\\p{Hiragana}]",
    "\\d+", "\\D", "\\h", "\\s", "\\S", "\\w+", "\\W", "\\R", "\\bcat\\b",
    "\\Bcat\\B", "\\Gcat", "\\A[a-z]+\\z", "\\Acat\\Z", "\\101", "\\x41", "\\u0041",
    "^cat$", ".", "a.c", "(?=a)a", "a(?!b)", "(?<=a)b", "(?<!a)b", "(a)\\1",
    "(?<word>ab)\\k<word>", "(a)\\g1", "(?<letter>a)\\g<letter>", "(a)?(?(1)b|c)",
    "(?<letter>a)?(?(<letter>)b|c)", "(?i:cat)", "(?m:.)", "(?x:a b)", "(?~real)",
    "(?~(a))", "(?~)", "(?# greeting)cat", "\\p{Alpha}+", "\\p{Han}"
  ].freeze

  def test_all_syntax_fixture_cases_reach_ast_generation
    cases = YAML.load_file(File.join(FIXTURES_ROOT, "syntax/core.yml")).fetch("cases")
    valid_cases = cases.reject { |fixture| fixture.fetch("outcome") == "error" }

    valid_cases.each do |fixture|
      result = Onibi::V2::Parser.parse(fixture.fetch("pattern"), options: fixture.fetch("options"))

      assert_instance_of Onibi::AST::Sequence, result.ast, fixture.fetch("name") unless result.ast.is_a?(Onibi::AST::Alternation)
      assert_ast_node(result.ast, fixture.fetch("name"))
    end
  end

  def test_codegen_and_fuzzer_patterns_reach_ast_generation
    patterns = YAML.load_file(File.join(FIXTURES_ROOT, "codegen/baseline.yml"))
                   .fetch("benchmark_cases").values.map { |entry| entry.fetch("pattern") }
    patterns.concat(YAML.load_file(File.join(FIXTURES_ROOT, "codegen/semantic_probes.yml"))
                    .map { |entry| entry.fetch("pattern") })
    patterns.concat(Fuzzer::PATTERNS)
    patterns.concat(V1_PATTERNS)

    patterns.uniq.each do |pattern|
      result = Onibi::V2::Parser.parse(pattern)

      assert_ast_node(result.ast, pattern)
    end
  end

  private

  def assert_ast_node(node, label)
    assert Onibi::AST.constants.any? { |name| node.is_a?(Onibi::AST.const_get(name)) }, label
    node.each_pair do |field, value|
      next unless %i[body parts branches expression yes_branch no_branch].include?(field)

      values = value.is_a?(Array) ? value : [value]
      values.each { |child| assert_ast_node(child, label) if child }
    end
  end
end
