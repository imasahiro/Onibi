# frozen_string_literal: true

require_relative "../../test_helper"

class CodegenAnalyzerTest < Minitest::Test
  def test_analysis_contains_labels_captures_and_widths
    ast = Onibi::Parser.new("(?<word>a+)\\g<word>").parse
    analysis = Onibi::Codegen::Analyzer.new(["ignorecase"], Encoding::UTF_8).analyze(ast)

    assert_equal [1], analysis.captures
    assert_equal({ "word" => 1 }, analysis.named_captures)
    assert_equal 1, analysis.subexpression_calls.length
    assert_equal 1, analysis.widths.fetch(ast).minimum
  end

  def test_analysis_graph_is_frozen
    analysis = Onibi::Codegen::Analyzer.new.analyze(Onibi::Parser.new("a").parse)

    assert analysis.frozen?
    assert analysis.labels.frozen?
    assert analysis.widths.values.all?(&:frozen?)
  end

  def test_unknown_ast_nodes_fail_during_analysis
    unknown = Struct.new(:value).new("x")

    error = assert_raises(Onibi::CodegenError) do
      Onibi::Codegen::Analyzer.new.analyze(unknown)
    end

    assert_match(/unsupported AST node/, error.message)
  end
end
