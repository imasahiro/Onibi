# frozen_string_literal: true

require_relative "../../test_helper"

class CodegenAnalyzerTest < Minitest::Test
  def test_boundary_analysis_can_be_disabled_for_runtime_codegen
    ast = Onibi::Parser.new("abc").parse
    analysis = Onibi::Codegen::Analyzer.new(boundary_analysis: false).analyze(ast)

    assert_nil analysis.boundary_facts
  end

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

  def test_analysis_extracts_literal_component_metadata
    analysis = analyze("cat|dog")

    assert_literal_component_metadata(analysis)
  end

  def test_analysis_extracts_sequence_run_and_anchor_facts
    analysis = analyze("\\Apre[a-z]fix\\z")

    assert_equal %w[pre fix], analysis.literal_runs.map(&:value)
    assert_equal ["pre"], analysis.prefix_literals.map(&:value)
    assert_equal ["fix"], analysis.suffix_literals.map(&:value)
    assert_equal %i[anchor_absolute_start anchor_absolute_end], analysis.anchor_facts.map(&:kind)
    assert_equal %i[prefix_literal suffix_literal], analysis.component_plans.map(&:kind)
  end

  def test_analysis_records_component_activation_conditions
    sequence = analyze("fix.*tail")
    alternation = analyze("cat|dog")

    assert_equal %i[candidate_start component_progress], sequence.component_plans.map(&:activation)
    assert_equal %i[candidate_start candidate_start], alternation.component_plans.map(&:activation)
  end

  def test_analysis_component_metadata_is_immutable
    analysis = analyze("cat|dog")

    assert_component_metadata_frozen(analysis)
  end

  def test_analysis_keeps_unsupported_string_shapes_on_baseline
    ignorecase = analyze("cat|dog", ["ignorecase"])
    unicode = analyze("café")

    assert_empty ignorecase.component_plans
    assert_empty unicode.component_plans
  end

  def test_analysis_excludes_non_ascii_literals_from_casefold_components
    analysis = analyze("é", ["ignorecase"])

    atom = analysis.literal_atoms.first
    assert_equal false, atom.ascii?
    refute atom.casefold?
    refute atom.fixed_width?
    assert_empty analysis.component_plans
  end

  def test_analysis_records_sequence_runs_as_required_literals
    analysis = analyze("pre[a-z]fix")

    assert_equal %w[pre fix], analysis.required_literals.map(&:value)
  end

  private

  def assert_literal_component_metadata(analysis)
    assert_equal %w[c a t d o g], analysis.literal_atoms.map(&:value)
    assert_equal %w[cat dog], analysis.literal_runs.map(&:value)
    assert_empty analysis.required_literals
    assert_equal %w[cat dog], analysis.prefix_literals.map(&:value)
    assert_equal %w[cat dog], analysis.suffix_literals.map(&:value)
    assert_component_sets(analysis)
  end

  def assert_component_sets(analysis)
    assert_equal %w[c d], analysis.first_sets.map(&:values).flatten
    assert_empty analysis.anchor_facts
    assert_equal %i[literal_alternation literal_alternation], analysis.component_plans.map(&:kind)
  end

  def assert_component_metadata_frozen(analysis)
    assert analysis.literal_atoms.frozen?
    assert analysis.literal_atoms.all?(&:frozen?)
    assert(analysis.literal_atoms.all? { |atom| atom.ascii? && atom.fixed_width? && !atom.casefold? })
    assert analysis.component_plans.all?(&:frozen?)
  end

  def analyze(pattern, options = [])
    Onibi::Codegen::Analyzer.new(options, Encoding::UTF_8).analyze(Onibi::Parser.new(pattern).parse)
  end
end
