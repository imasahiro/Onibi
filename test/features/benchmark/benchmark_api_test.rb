# frozen_string_literal: true

require_relative "../../test_helper"
require_relative "../../../benchmark/regex_redux"
require_relative "../../../benchmark/regexp_features"

class BenchmarkApiTest < Minitest::Test
  def test_regex_redux_matches_mri_output
    input = File.read(File.join(__dir__, "../../../benchmark/fasta-500.txt"))
    ruby = RegexRedux.new(StringIO.new(input), engine: :ruby).to_s
    onibi = RegexRedux.new(StringIO.new(input), engine: :onibi).to_s
    assert_equal ruby, onibi
  end

  def test_feature_corpus_has_mri_match_behavior
    RegexpFeatureBenchmark::Suite.load.cases.each do |benchmark_case|
      assert_equal benchmark_case.ruby_regexp.match?(benchmark_case.input),
                   benchmark_case.onibi_regexp.match?(benchmark_case.input),
                   benchmark_case.label
    end
  end

  def test_feature_corpus_contains_compiled_rseq_cases
    rseq_cases = RegexpFeatureBenchmark::Suite.load.cases.select do |benchmark_case|
      benchmark_case.onibi_regexp.pipeline[:vm] == :RSEQ
    end
    assert_operator rseq_cases.length, :>=, 5
    assert_includes rseq_cases.map(&:label), "character_classes/ascii/range"
    assert_includes rseq_cases.map(&:label), "greedy_quantifier/ascii/bounded-repeat"
    assert_includes rseq_cases.map(&:label), "options/ascii/multiline-dot"
    assert_includes rseq_cases.map(&:label), "options/ascii/ignore-case"
  end

  def test_rseq_vm_matches_mri_for_dispatched_cases
    RegexpFeatureBenchmark::Suite.load.cases.each do |benchmark_case|
      regexp = benchmark_case.onibi_regexp
      next unless regexp.pipeline[:vm] == :RSEQ

      assert_equal benchmark_case.ruby_regexp.match?(benchmark_case.input),
                   regexp.vm_match?(benchmark_case.input),
                   "RSeq #{benchmark_case.label}"
    end
  end

  def test_rseq_contains_immutable_relocatable_blob
    blob = Onibi::Regexp.new("abc").pipeline[:rseq_program][:blob]

    assert_predicate blob, :frozen?
    assert_operator blob.bytesize, :>=, 80
    assert_equal 0x4f4e5251, blob.unpack1("L<")
    assert_equal 1, blob.byteslice(4, 2).unpack1("S<")
    assert_equal 0, blob.getbyte(6)
    dynamic = Onibi::Regexp.new("(a)\\1").pipeline[:rseq_program][:blob]
    assert_equal 2, dynamic.getbyte(6)
    header = Onibi::Regexp.new("[a-z]").pipeline[:rseq_program][:header]
    assert_equal 1, header[:class_count]
  end

  def test_rseq_materializes_literal_and_class_descriptor_sections
    literal = Onibi::Regexp.new("abc").pipeline[:rseq_program]
    class_program = Onibi::Regexp.new("[a-z]").pipeline[:rseq_program]
    [literal, class_program].each do |program|
      header = program[:header]
      %i[states_offset edges_offset actions_offset classes_offset literals_offset descriptors_offset subprograms_offset].each do |key|
        assert_operator header.fetch(key), :>, 0
        assert_equal 0, header.fetch(key) % 4
      end
      assert_equal header[:blob_size], header[:subprograms_offset]
      assert_equal header[:blob_size], program[:blob].bytesize
    end
    assert_equal 3, literal[:header][:literal_count]
    assert_equal 1, Onibi::Regexp.new("aa").pipeline[:rseq_program][:header][:literal_count]
    assert_equal 1, class_program[:header][:class_count]
    assert_equal 1, Onibi::Regexp.new("[a][a]").pipeline[:rseq_program][:header][:class_count]
  end

  def test_literal_pipeline_exposes_compiler_stages
    pipeline = Onibi::Regexp.new("abc").pipeline
    assert_equal(%i[literal literal literal], pipeline[:tokens].map { |token| token[:kind] })
    assert_equal([97, 98, 99], pipeline[:rseq].map { |op| op[:arg][:byte] })
    assert_equal :sequence, pipeline[:ast][:type]
    assert_equal(%i[literal literal literal], pipeline[:ast][:children].map { |node| node[:type] })
    assert_equal :RSEQ, pipeline[:vm]
    assert_equal :REGULAR_FAST, pipeline[:interpreter]
    assert_equal :ACCEPT, pipeline[:gir_graph][:states].last[:op]
    assert_equal :G_ACCEPT, pipeline[:gir_graph][:states].last[:gir_op]
    assert_equal :G_CHAR, pipeline[:gir_graph][:states].first[:gir_op]
    assert_equal({ from: 0, to: 1, actions: [] }, pipeline[:gir_graph][:edges].first)
    assert_equal 0, pipeline[:gir_graph][:start]
    assert_equal [{ op: :STRING, arg: "abc" }], pipeline[:rseq_compact]
    assert_equal [{ op: :RUN_CLASS, arg: "[ab]" }], Onibi::Regexp.new("[ab]").pipeline[:rseq_compact]
    assert_equal [{ op: :RUN_ANY, arg: 1 }], Onibi::Regexp.new(".").pipeline[:rseq_compact]
    assert_equal [{ op: :RUN_CLASS, arg: "[a-z]+[0-9]+" }], Onibi::Regexp.new("[a-z]+[0-9]+").pipeline[:rseq_compact]
    assert_equal [{ op: :RUN_CLASS, arg: "[a-z]+" }], Onibi::Regexp.new("[a-z]+").pipeline[:rseq_compact]
    assert_equal [{ op: :REPEAT, atom: "a", bounds: "2,3" }], Onibi::Regexp.new("a{2,3}").pipeline[:rseq_compact]
  end

  def test_literal_rseq_vm_matches_substring
    regexp = Onibi::Regexp.new("abc")
    assert regexp.vm_match?("xxabcxx")
    refute regexp.vm_match?("xxabxx")
    assert_equal({ start: 2, end: 5 }, regexp.vm_match_result("xxabcxx"))
    refute regexp.match?("abc", 1)
  end

  def test_tokenizer_marks_classes_and_alternation
    kinds = Onibi::Regexp.new("[ab]|cd").pipeline[:tokens].map { |token| token[:kind] }
    assert_equal %i[class_start literal literal class_end alternation literal literal], kinds
  end

  def test_single_character_alternation_rseq_vm
    regexp = Onibi::Regexp.new("a|b")
    assert_equal :RSEQ, regexp.pipeline[:vm]
    assert regexp.vm_match?("xxbxx")
    refute regexp.vm_match?("xxcxx")
    edges = regexp.pipeline[:gir_graph][:edges]
    assert_equal([0, 2], edges.map { |edge| edge[:to] })
  end

  def test_alternation_raw_result_preserves_priority
    result = Onibi::Regexp.new("foo|bar").vm_match_result("bar foo")
    assert_equal({ start: 0, end: 3 }, result)
  end

  def test_multi_character_alternation_rseq_vm
    regexp = Onibi::Regexp.new("foo|bar")
    assert regexp.vm_match?("xxbarxx")
    refute regexp.vm_match?("xxbazxx")
    assert_equal :alternation, regexp.pipeline[:ast][:type]
    graph = regexp.pipeline[:gir_graph]
    assert_equal graph[:states].last[:id], graph[:start]
    assert_equal [{ op: :ALT, branches: %w[foo bar] }], regexp.pipeline[:rseq_compact]
    assert_equal(%i[literal literal literal], regexp.pipeline[:ast][:branches].first[:children].map { |node| node[:type] })
  end

  def test_rseq_class_sequence_public_match
    regexp = Onibi::Regexp.new("[a]b")
    assert_equal :RSEQ, regexp.pipeline[:vm]
    assert regexp.match?("xxabxx")
    refute regexp.match?("xxacxx")
  end

  def test_quantifier_ast_and_repeat_opcode
    pipeline = Onibi::Regexp.new("a{2,3}").pipeline
    assert_equal :quantifier, pipeline[:ast][:type]
    assert_includes pipeline[:rseq].map { |op| op[:op] }, :REPEAT
    assert_equal 2, pipeline[:ast][:min]
    assert_equal 3, pipeline[:ast][:max]
    assert pipeline[:ast][:greedy]
  end

  def test_class_and_anchor_ast_types
    assert_equal :character_class, Onibi::Regexp.new("[ab]").pipeline[:ast][:type]
    assert_equal :anchor, Onibi::Regexp.new("^abc$").pipeline[:ast][:type]
    assert_equal [[97, 122]], Onibi::Regexp.new("[a-z]").pipeline[:ast][:ranges]
  end

  def test_literal_wildcard_sequence_rseq_vm
    regexp = Onibi::Regexp.new("a.c")
    assert_equal :RSEQ, regexp.pipeline[:vm]
    assert regexp.vm_match?("xxabcxx")
    refute regexp.vm_match?("xxacxx")
    refute regexp.vm_match?("xxa\ncxx")
    assert_equal({ start: 2, end: 5 }, regexp.vm_match_result("xxabcxx"))
  end

  def test_wildcard_repeat_sequence_rseq_vm
    regexp = Onibi::Regexp.new("a.*z")
    assert_equal :RSEQ, regexp.pipeline[:vm]
    assert regexp.vm_match?("a-middle-z")
    refute regexp.vm_match?("a-middle")
  end

  def test_bounded_repeat_dispatches_to_rseq
    regexp = Onibi::Regexp.new("a{2,3}")
    assert_equal :RSEQ, regexp.pipeline[:vm]
    assert_equal :TAGGED_ORDERED, regexp.pipeline[:interpreter]
    assert regexp.match?("baaaac")
    refute regexp.match?("bc")
  end

  def test_quantifier_gir_has_ordered_repeat_cycle
    edges = Onibi::Regexp.new("a*").pipeline[:gir_graph][:edges]
    assert_equal [{ from: 0, to: 1, actions: [] },
                  { from: 1, to: 0, actions: [] },
                  { from: 1, to: 2, actions: [] }], edges
  end

  def test_bounded_repeat_gir_has_counter_actions
    edges = Onibi::Regexp.new("a{2,3}").pipeline[:gir_graph][:edges]
    assert_equal :COUNTER_INIT, edges.first[:actions].first[:op]
    assert_equal :COUNTER_INCREMENT, edges[1][:actions].first[:op]
  end

  def test_simple_character_class_dispatches_to_rseq
    regexp = Onibi::Regexp.new("[ab]")
    assert_equal :RSEQ, regexp.pipeline[:vm]
    bitmap = regexp.pipeline[:canonical][:gir][:states].first[:payload][:bitmap]
    assert_equal 32, bitmap.bytesize
    assert_predicate bitmap, :frozen?
    assert regexp.match?("xxbxx")
    refute regexp.match?("xxcxx")
  end

  def test_character_class_repeat_dispatches_to_rseq
    regexp = Onibi::Regexp.new("[a-z]+")
    assert_equal :RSEQ, regexp.pipeline[:vm]
    assert regexp.match?("item-2026")
    refute regexp.match?("123")
  end

  def test_character_class_pair_repeat_dispatches_to_rseq
    regexp = Onibi::Regexp.new("[a-z]+[0-9]+")
    assert_equal :RSEQ, regexp.pipeline[:vm]
    assert regexp.match?("token-abc123-end")
    refute regexp.match?("token-abc-end")
  end

  def test_dynamic_features_select_dynamic_interpreter
    assert_equal :DYNAMIC, Onibi::Regexp.new("(a)-\\1").pipeline[:interpreter]
  end

  def test_anchor_assertions_are_edge_actions
    edges = Onibi::Regexp.new("^abc$").pipeline[:gir_graph][:edges]
    assert_equal :ASSERT_BEGIN_BUFFER, edges.first[:actions].first[:op]
    assert_equal :ASSERT_END_BUFFER, edges.last[:actions].first[:op]
  end

  def test_buffer_anchor_tokens
    tokens = Onibi::Regexp.new("\\Aabc\\z").pipeline[:tokens]
    assert_equal :anchor, tokens.first[:kind]
    assert_equal :anchor, tokens.last[:kind]
    assert_equal :anchor, Onibi::Regexp.new("\\Aabc\\z").pipeline[:ast][:type]
    regexp = Onibi::Regexp.new("\\Aabc\\z")
    assert regexp.match?("abc")
    refute regexp.match?("xabc")
    graph = Onibi::Compiler.compile(Onibi::Parser.parse("\\Ga"))[:graph]
    assert_equal :ASSERT_SEARCH_ORIGIN, graph[:start_edges].first[:actions].first[:op]
  end

  def test_pipeline_tokenizes_escapes_as_single_semantic_units
    pipeline = Onibi::Regexp.new("\\.\\d\\A").pipeline

    assert_equal(%i[literal escape anchor], pipeline[:tokens].map { |token| token[:kind] })
    assert_equal([46, 100, 65], pipeline[:tokens].map { |token| token[:byte] })
    assert_equal([[0, 2], [2, 4], [4, 6]], pipeline[:tokens].map { |token| [token[:start], token[:end]] })
    assert_equal(%i[CHAR ESCAPE ASSERT], pipeline[:gir].map { |op| op[:op] })
  end

  def test_rseq_header_marks_semi_end_assertion_feature
    rseq = Onibi::Regexp.new("a\\Z").pipeline[:rseq_program]
    assert_equal true, (rseq[:header][:features] & 16) != 0
    assert_includes rseq[:actions].map { |action| action[:op] }, :ASSERT_SEMI_END_BUFFER
  end

  def test_lexer_publishes_an_immutable_token_stream
    lexer = Onibi::Lexer.new("a\\d")
    tokens = lexer.tokens

    assert_equal(%i[literal escape], tokens.map { |token| token[:kind] })
    assert_equal([[0, 1], [1, 3]], tokens.map { |token| [token[:start], token[:end]] })
    assert_predicate lexer, :frozen?
    assert_predicate tokens, :frozen?
    assert tokens.all?(&:frozen?)
    assert_same tokens, lexer.tokens
  end

  def test_lexer_keeps_character_class_operators_inside_the_class
    tokens = Onibi::Lexer.new("[a-z+|]").tokens

    assert_equal(%i[class_start literal class_range literal literal literal class_end],
                 tokens.map { |token| token[:kind] })
  end

  def test_parser_consumes_lexer_tokens_to_build_regular_ast
    parsed = Onibi::Parser.parse("a|[b-d]+?")

    assert_equal "a|[b-d]+?", parsed[:source]
    assert_equal :alternative, parsed[:ast][:type]
    assert_equal(%i[sequence sequence], parsed[:ast][:branches].map { |branch| branch[:type] })
    assert_equal :literal, parsed[:ast][:branches][0][:children][0][:type]
    quantifier = parsed[:ast][:branches][1][:children][0]
    assert_equal :quantifier, quantifier[:type]
    assert_equal 1, quantifier[:min]
    assert_nil quantifier[:max]
    refute quantifier[:greedy]
    assert_equal [[98, 100]], quantifier[:atom][:ranges]
    assert_predicate parsed, :frozen?

    open_ended = Onibi::Parser.parse("a{2,}")[:ast][:children].first
    assert_equal 2, open_ended[:min]
    assert_nil open_ended[:max]

    lazy = Onibi::Parser.parse("a{2,4}?")[:ast][:children].first
    refute lazy[:greedy]
    possessive = Onibi::Parser.parse("a{2,4}+")[:ast][:children].first
    assert possessive[:possessive]
  end

  def test_parser_rejects_invalid_character_class_range_endpoints
    assert_raises(Onibi::RegexpError) { Onibi::Parser.parse("[a-\\d]") }
    assert_raises(Onibi::RegexpError) { Onibi::Parser.parse("[z-a]") }
  end

  def test_parser_records_anchor_and_escape_semantics
    ast = Onibi::Parser.parse("\\A\\d\\z")[:ast]
    children = ast[:children]

    assert_equal :anchor_start, children[0][:kind]
    assert_equal :escape, children[1][:type]
    assert_equal "d", children[1][:name]
    assert_equal :anchor_end, children[2][:kind]
  end

  def test_parser_records_positive_and_negative_lookahead_nodes
    positive = Onibi::Parser.parse("(?=a)b")[:ast]
    negative = Onibi::Parser.parse("(?!a)b")[:ast]
    assert_equal :lookahead, positive[:children].first[:type]
    assert_equal true, positive[:children].first[:positive]
    assert_equal false, negative[:children].first[:positive]
    assert_equal :lookahead_start, Onibi::Lexer.new("(?=a)b").tokens.first[:kind]
  end

  def test_parser_matches_nested_group_boundaries_across_group_kinds
    ast = Onibi::Parser.parse("(?=(?:a))a")[:ast]
    lookahead = ast[:children].first
    assert_equal :lookahead, lookahead[:type]
    assert_equal :group, lookahead[:body][:children].first[:type]
  end

  def test_literal_lookahead_executes_as_zero_width_gir_action
    positive = Onibi::Regexp.new("(?=a)a")
    negative = Onibi::Regexp.new("(?!a)b")
    assert positive.program_cached?
    assert positive.vm_match?("za")
    refute positive.vm_match?("zb")
    refute negative.vm_match?("a")
    assert negative.vm_match?("b")
    assert_equal :ASSERT_LOOKAHEAD,
                 positive.pipeline[:compiled][:graph][:start_edges].first[:actions].first[:op]
  end

  def test_literal_lookbehind_executes_with_fixed_width_assertion
    positive = Onibi::Regexp.new("(?<=a)a")
    negative = Onibi::Regexp.new("(?<!a)b")
    assert positive.program_cached?
    assert positive.vm_match?("aa")
    refute positive.vm_match?("ba")
    refute negative.vm_match?("ab")
    assert negative.vm_match?("cb")
    assert_equal :ASSERT_LOOKBEHIND,
                 positive.pipeline[:compiled][:graph][:start_edges].first[:actions].first[:op]
  end

  def test_non_capturing_group_is_semantic_and_does_not_allocate_capture
    parsed = Onibi::Parser.parse("(?:ab)")
    node = parsed[:ast][:children].first
    assert_equal :group, node[:type]
    refute node[:capturing]
    regexp = Onibi::Regexp.new("(?:ab)")
    assert_equal :REGULAR_FAST, regexp.execution_class.to_sym
    assert regexp.vm_match?("zab")
  end

  def test_atomic_group_is_semantic_and_rejected_before_partial_lowering
    node = Onibi::Parser.parse("(?>a)")[:ast][:children].first
    assert_equal :atomic, node[:type]
    regexp = Onibi::Regexp.new("(?>a)")
    refute regexp.program_cached?
    assert regexp.match?("a")
    assert_equal :DYNAMIC, regexp.execution_class.to_sym
  end

  def test_literal_lookaround_stays_regular_when_no_tag_state_is_needed
    assert_equal :REGULAR_FAST, Onibi::Regexp.new("(?=a)b").execution_class.to_sym
  end

  def test_unimplemented_quantifier_ordering_modifiers_use_mri_boundary
    lazy = Onibi::Regexp.new("a+?")
    possessive = Onibi::Regexp.new("a++")
    refute lazy.program_cached?
    refute possessive.program_cached?
    assert_equal "a", lazy.match("aaa")[0]
    assert_equal "aaa", possessive.match("aaa")[0]
  end

  def test_encoding_flags_are_parsed_but_not_sent_to_ascii_rseq
    assert_equal ["fixedencoding"], Onibi::Parser.parse("a", 16)[:options]
    assert_equal ["noencoding"], Onibi::Parser.parse("a", 32)[:options]
    refute Onibi::Regexp.new("a", 16).program_cached?
    refute Onibi::Regexp.new("a", 32).program_cached?
  end

  def test_shorthand_escape_classes_compile_to_bitmaps
    digit = Onibi::Regexp.new("\\d")
    non_digit = Onibi::Regexp.new("\\D")
    assert digit.program_cached?
    assert digit.vm_match?("7")
    refute digit.vm_match?("x")
    assert non_digit.vm_match?("x")
    refute non_digit.vm_match?("7")
  end

  def test_unsupported_subroutine_calls_are_classified_by_tokens
    tokens = Onibi::Lexer.new("\\g<name>").tokens
    assert_equal :subroutine, tokens.first[:kind]
    ast = Onibi::Parser.parse("\\g<name>")[:ast]
    assert_equal :subroutine, ast[:children].first[:type]
    assert_equal "name", ast[:children].first[:name]
    assert_raises(RegexpError) { Onibi::Regexp.new("\\g<name>") }
  end

  def test_class_intersection_stays_out_of_ascii_rseq
    regexp = Onibi::Regexp.new("[a&&b]")
    refute regexp.program_cached?
    assert_equal Onibi::Regexp.new("[a&&b]").match?("a"), regexp.match?("a")
  end

  def test_shorthand_escapes_inside_classes_use_bitmap_predicates
    digit = Onibi::Regexp.new("[\\d]")
    assert digit.program_cached?
    assert digit.vm_match?("5")
    refute digit.vm_match?("q")
  end

  def test_control_escapes_become_literal_bytes
    { "\\n" => "\n", "\\r" => "\r", "\\t" => "\t", "\\f" => "\f" }.each do |pattern, input|
      regexp = Onibi::Regexp.new(pattern)
      assert regexp.program_cached?
      assert regexp.vm_match?(input)
    end
  end

  def test_hex_escape_is_one_literal_token
    regexp = Onibi::Regexp.new("\\x41")
    assert_equal [{ kind: :literal, byte: 65, start: 0, end: 5 }], regexp.pipeline[:tokens]
    assert regexp.vm_match?("A")
    assert Onibi::Regexp.new("\\x4").vm_match?("x4")
  end

  def test_octal_zero_escape_is_a_literal_byte
    regexp = Onibi::Regexp.new("\\007")
    assert_equal 7, regexp.pipeline[:tokens].first[:byte]
    assert regexp.vm_match?("\a")
  end

  def test_unicode_escape_does_not_enter_ascii_rseq
    regexp = Onibi::Regexp.new("\\u{41}")
    refute regexp.program_cached?
    assert regexp.match?("A")
  end

  def test_nullable_program_keeps_immediate_accept_start_edge
    empty = Onibi::Regexp.new("")
    optional = Onibi::Regexp.new("a?")
    assert empty.program_cached?
    assert_equal({ start: 0, end: 0 }, empty.vm_match_result("xyz"))
    assert optional.vm_match?("xyz")
    assert_equal 0, optional.vm_match_result("xyz")[:start]
  end

  def test_extended_option_lowers_whitespace_before_parsing
    regexp = Onibi::Regexp.new("a b", 2)
    assert regexp.program_cached?
    assert regexp.vm_match?("ab")
    refute regexp.vm_match?("a b")
    assert Onibi::Regexp.new("a# comment\nb", 2).vm_match?("ab")
    assert Onibi::Regexp.new("a\\ b", 2).vm_match?("a b")
    assert Onibi::Regexp.new("a\\#b", 2).vm_match?("a#b")
  end

  def test_constructor_accepts_string_options
    assert Onibi::Regexp.new("a", "i").vm_match?("A")
  end

  def test_parser_preserves_option_scope_metadata
    tokens = Onibi::Lexer.new("(?im:a)").tokens
    assert_equal :option_scope_start, tokens.first[:kind]
    ast = Onibi::Parser.parse("(?-x:a)")[:ast]
    assert_equal :option_scope, ast[:children].first[:type]
    assert_equal "x", ast[:children].first[:options]
    assert ast[:children].first[:negative]
  end

  def test_tokenizer_applies_scoped_extended_whitespace_rules
    enabled = Onibi::Lexer.new("(?x:a b)").tokens
    disabled = Onibi::Lexer.new("(?-x:a b)").tokens
    assert_equal %i[option_scope_start literal literal group_end], enabled.map { |token| token[:kind] }
    assert_equal %i[option_scope_start literal literal literal group_end], disabled.map { |token| token[:kind] }
  end

  def test_compiler_uses_tokenized_scoped_extended_body
    enabled = Onibi::Regexp.new("(?x:a b)")
    disabled = Onibi::Regexp.new("(?-x:a b)")
    assert enabled.program_cached?
    assert enabled.vm_match?("ab")
    refute disabled.vm_match?("ab")
    assert disabled.vm_match?("a b")
  end

  def test_tokenizer_keeps_comma_and_space_as_literals
    assert_equal :literal, Onibi::Lexer.new(",").tokens.first[:kind]
    assert Onibi::Regexp.new("a b").vm_match?("a b")
  end

  def test_tokenizer_keeps_multibyte_literal_as_one_token
    token = Onibi::Lexer.new("é").tokens.first
    assert_equal :literal, token[:kind]
    assert_equal "é", token[:bytes]
    assert_equal({ type: :literal, start: 0, end: 2, byte: 0xc3, bytes: "é" },
                  Onibi::Parser.parse("é")[:ast][:children].first)
  end

  def test_parser_keeps_invalid_repeat_braces_literal
    regexp = Onibi::Regexp.new("a{}")
    assert regexp.vm_match?("a{}")
    refute regexp.vm_match?("a")
    assert_equal %i[literal literal literal], regexp.pipeline[:canonical][:ast][:children].map { |node| node[:type] }
  end

  def test_parser_accepts_open_repeat_bounds
    lower_open = Onibi::Regexp.new("\\Aa{,2}\\z")
    upper_open = Onibi::Regexp.new("\\Aa{2,}\\z")
    assert lower_open.vm_match?("")
    refute lower_open.vm_match?("aaa")
    assert upper_open.vm_match?("aa")
  end

  def test_compiler_resolves_local_case_and_line_options
    case_scope = Onibi::Regexp.new("(?i:a)")
    assert case_scope.vm_match?("A")
    refute case_scope.vm_match?("B")
    line_scope = Onibi::Regexp.new("(?m:.)")
    assert line_scope.vm_match?("\n")
    inverse = Onibi::Regexp.new("(?-i:a)", 1)
    refute inverse.vm_match?("A")
  end

  def test_lazy_optional_preserves_exit_priority
    regexp = Onibi::Regexp.new("a??b")
    assert regexp.vm_match?("b")
    assert_equal({ start: 0, end: 1 }, regexp.vm_match_result("b"))
    assert regexp.vm_match?("ab")
  end

  def test_tagged_capture_walk_keeps_distinct_capture_histories
    regexp = Onibi::Regexp.new("(a|aa)\\1")
    assert regexp.vm_match?("aaaa")
    result = regexp.vm_match_result("aaaa")
    assert_equal({ start: 0, end: 2, captures: { 1 => { start: 0, end: 1 } } }, result)
  end

  def test_parser_rejects_invalid_regular_core_syntax
    assert_raises(Onibi::RegexpError) { Onibi::Parser.parse("[abc") }
    assert_raises(Onibi::RegexpError) { Onibi::Parser.parse("a{3,2}") }
    assert_raises(Onibi::RegexpError) { Onibi::Parser.parse("a**") }
    assert_raises(ArgumentError) { Onibi::Parser.parse("a", 8) }
  end

  def test_compiler_builds_gir_from_ast_without_source_inspection
    compiled = Onibi::Compiler.compile(Onibi::Parser.parse("a|b"))
    graph = compiled[:graph]

    assert_equal(%i[G_CHAR G_CHAR G_ACCEPT], graph[:states].map { |state| state[:op] })
    assert_equal([[0], [1]], graph[:start_edges].map { |edge| [edge[:to]] })
    assert_equal :G_ACCEPT, graph[:states][graph[:accept]][:op]
    assert_equal([[0, 2], [1, 2]], graph[:edges].map { |edge| [edge[:from], edge[:to]] })
    assert_predicate compiled, :frozen?
  end

  def test_compiler_lowers_buffer_anchors_to_edge_actions
    graph = Onibi::Compiler.compile(Onibi::Parser.parse("\\Aa\\z"))[:graph]

    assert_equal :ASSERT_BEGIN_BUFFER, graph[:start_edges].first[:actions].first[:op]
    assert_equal :ASSERT_END_BUFFER, graph[:edges].last[:actions].first[:op]
    semi = Onibi::Compiler.compile(Onibi::Parser.parse("a\\Z"))[:graph]
    assert_equal :ASSERT_SEMI_END_BUFFER, semi[:edges].last[:actions].first[:op]
  end

  def test_semi_end_anchor_accepts_one_final_newline
    regexp = Onibi::Regexp.new("a\\Z")
    assert regexp.vm_match?("a")
    assert regexp.vm_match?("a\n")
    refute regexp.vm_match?("a\nb")
  end

  def test_compiler_keeps_all_glushkov_starts_for_nullable_prefix
    graph = Onibi::Compiler.compile(Onibi::Parser.parse("a?b"))[:graph]

    assert_equal([0, 1], graph[:start_edges].map { |edge| edge[:to] })
    assert_equal([[0, 1], [1, 2]], graph[:edges].map { |edge| [edge[:from], edge[:to]] })
  end

  def test_rseq_lowering_preserves_immutable_program_order
    compiled = Onibi::Compiler.compile(Onibi::Parser.parse("a{2,3}"))
    rseq = Onibi::RSeq.lower(compiled)

    assert_equal 1, rseq[:header][:version]
    assert_equal compiled[:graph][:states].length, rseq[:header][:state_count]
    assert_equal compiled[:graph][:edges].length, rseq[:header][:edge_count]
    assert_equal rseq[:header][:edge_count], rseq[:edges].length
    assert_equal rseq[:header][:edge_count], rseq[:header][:start_edge_base]
    assert_equal :COUNTER_INIT, rseq[:start_edges].first[:actions].first[:op]
    assert_equal :COUNTER_INCREMENT, rseq[:actions].first[:op]
    assert_predicate rseq, :frozen?
    assert_predicate rseq[:header], :frozen?
    assert_predicate rseq[:edges].first, :frozen?
    invalid = { graph: { states: [], edges: [], start_edges: [], accept: 0 } }
    assert_raises(ArgumentError) { Onibi::RSeq.lower(invalid) }
  end

  def test_rseq_lowering_does_not_mutate_gir_actions
    compiled = Onibi::Compiler.compile(Onibi::Parser.parse("(a)"))
    input_action = compiled[:graph][:start_edges].first[:actions].first
    refute_predicate input_action, :frozen?
    rseq = Onibi::RSeq.lower(compiled)
    refute_predicate input_action, :frozen?
    assert_predicate rseq[:start_edges].first[:actions].first, :frozen?
    refute_same input_action, rseq[:start_edges].first[:actions].first
  end

  def test_rseq_action_programs_have_explicit_end_markers
    rseq = Onibi::Regexp.new("(a)").pipeline[:rseq_program]
    programs = rseq[:edges].map { |edge| edge[:actions] } + rseq[:start_edges].map { |edge| edge[:actions] }
    programs.reject(&:empty?).each do |actions|
      assert_equal :END, actions.last[:op]
    end
    assert_includes rseq[:actions].map { |action| action[:op] }, :END
  end

  def test_rseq_empty_action_edges_use_zero_offset
    rseq = Onibi::Regexp.new("\\bcat\\b").pipeline[:rseq_program]
    empty_edges = rseq[:edges].select { |edge| edge[:actions].empty? }
    refute_empty empty_edges
    assert empty_edges.all? { |edge| edge[:action_offset].zero? }
  end

  def test_vm_rejects_an_unterminated_rseq_action_program
    rseq = Onibi::Regexp.new("(a)").pipeline[:rseq_program]
    starts = rseq[:start_edges].map.with_index do |edge, index|
      index.zero? ? edge.merge(actions: edge[:actions][0...-1].freeze).freeze : edge
    end.freeze
    invalid = rseq.merge(start_edges: starts)
    invalid.freeze
    assert_raises(ArgumentError) { Onibi::VM.execute(invalid, "a", :TAGGED_ORDERED) }
  end

  def test_vm_rejects_rseq_semantic_flag_mismatch
    regexp = Onibi::Regexp.new("abc")
    rseq = regexp.pipeline[:rseq_program]
    invalid = rseq.dup
    invalid_header = rseq[:header].dup
    invalid_header[:ignorecase] = true
    invalid[:header] = invalid_header
    assert_raises(ArgumentError) { Onibi::VM.execute(invalid, "abc", :REGULAR_FAST) }
  end

  def test_vm_rejects_rseq_start_edge_base_mismatch
    rseq = Onibi::Regexp.new("abc").pipeline[:rseq_program]
    invalid_header = rseq[:header].merge(start_edge_base: 0).freeze
    invalid = rseq.merge(header: invalid_header)
    invalid.freeze
    assert_raises(ArgumentError) { Onibi::VM.execute(invalid, "abc", :REGULAR_FAST) }
  end

  def test_vm_rejects_semantic_physical_state_mismatch
    regexp = Onibi::Regexp.new("abc")
    rseq = regexp.pipeline[:rseq_program]
    invalid = rseq.dup
    invalid_states = rseq[:states].dup
    invalid_states[0] = rseq[:states][0].merge(op: :G_ANY)
    invalid[:states] = invalid_states
    assert_raises(ArgumentError) { Onibi::VM.execute(invalid, "abc", :REGULAR_FAST) }
  end

  def test_vm_rejects_missing_semantic_rseq_arrays
    rseq = Onibi::Regexp.new("abc").pipeline[:rseq_program]
    assert_raises(ArgumentError) { Onibi::VM.execute(rseq.merge(edges: []), "abc", :REGULAR_FAST) }
    assert_raises(ArgumentError) { Onibi::VM.execute(rseq.merge(actions: []), "abc", :REGULAR_FAST) }
  end

  def test_vm_rejects_semantic_physical_edge_mismatch
    rseq = Onibi::Regexp.new("abc").pipeline[:rseq_program]
    edge = rseq[:edges].first.merge(to: 2)
    invalid = rseq.merge(edges: [edge] + rseq[:edges].drop(1))
    assert_raises(ArgumentError) { Onibi::VM.execute(invalid, "abc", :REGULAR_FAST) }
  end

  def test_vm_rejects_semantic_physical_start_edge_mismatch
    rseq = Onibi::Regexp.new("abc").pipeline[:rseq_program]
    invalid = rseq.merge(start_edges: [rseq[:start_edges].first.merge(to: 1)])
    assert_raises(ArgumentError) { Onibi::VM.execute(invalid, "abc", :REGULAR_FAST) }
  end

  def test_vm_rejects_semantic_physical_action_mismatch
    rseq = Onibi::Regexp.new("\\bcat\\b").pipeline[:rseq_program]
    invalid_actions = rseq[:actions].map.with_index { |action, i| i.zero? ? action.merge(op: :MATCH_RESET) : action }
    invalid = rseq.merge(actions: invalid_actions)
    assert_raises(ArgumentError) { Onibi::VM.execute(invalid, "cat", :REGULAR_FAST) }
  end

  def test_vm_rejects_invalid_cached_physical_execution_view
    rseq = Onibi::Regexp.new("abc").pipeline[:rseq_program]
    invalid_view = rseq[:physical_graph].merge(states: [])
    assert_raises(ArgumentError) { Onibi::VM.execute(rseq.merge(physical_graph: invalid_view), "abc", :REGULAR_FAST) }
  end

  def test_vm_rejects_unknown_rseq_action_opcode
    rseq = Onibi::Regexp.new("(a)").pipeline[:rseq_program]
    actions = rseq[:actions].dup
    actions[0] = actions[0].merge(op: :UNKNOWN).freeze
    invalid = rseq.merge(actions: actions.freeze).freeze
    assert_raises(ArgumentError) { Onibi::VM.execute(invalid, "a", :TAGGED_ORDERED) }
  end

  def test_vm_rejects_non_hash_semantic_entries
    rseq = Onibi::Regexp.new("abc").pipeline[:rseq_program]
    states = rseq[:states].dup
    states[0] = nil
    assert_raises(ArgumentError) { Onibi::VM.execute(rseq.merge(states: states), "abc", :REGULAR_FAST) }
  end

  def test_gir_declares_capture_and_counter_resources
    capture_graph = Onibi::Compiler.compile(Onibi::Parser.parse("(a)"))[:graph]
    repeat_graph = Onibi::Compiler.compile(Onibi::Parser.parse("a{2,3}"))[:graph]
    assert_equal 1, capture_graph[:capture_count]
    assert_equal 0, capture_graph[:counter_count]
    assert_equal 0, repeat_graph[:capture_count]
    assert_equal 1, repeat_graph[:counter_count]
  end

  def test_parser_normalizes_duplicate_lexical_options
    assert_equal %w[ignorecase multiline], Onibi::Parser.parse("a", "iim")[:options]
  end

  def test_parser_accepts_named_option_arrays
    parsed = Onibi::Parser.parse("a # comment\n b", ["extended"])
    assert_equal ["extended"], parsed[:options]
    assert_equal ["a", "b"], parsed[:tokens].select { |token| token[:kind] == :literal }.map { |token| token[:byte].chr }
  end

  def test_parser_publishes_an_immutable_ast_graph
    ast = Onibi::Parser.parse("(ab|c)")[:ast]
    assert_predicate ast, :frozen?
    assert_predicate ast[:children], :frozen?
    assert_predicate ast[:children].first, :frozen?
    assert_raises(FrozenError) { ast[:children] << { type: :literal } }
  end

  def test_rseq_publishes_an_immutable_physical_execution_view
    rseq = Onibi::Regexp.new("abc").pipeline[:rseq_program]
    view = rseq[:physical_graph]
    assert_predicate view, :frozen?
    assert_predicate view[:states], :frozen?
    assert_predicate view[:edges], :frozen?
    assert_predicate view[:start_edges], :frozen?
    assert_raises(FrozenError) { view[:states] << {} }
  end

  def test_parser_rejects_overflowing_quantifier_counts
    assert_raises(Onibi::RegexpError) { Onibi::Parser.parse("a{999999999999999999999}") }
    assert_raises(Onibi::RegexpError) { Onibi::Parser.parse("a{-1}") }
  end

  def test_compiler_lowers_capture_boundaries_to_actions
    graph = Onibi::Compiler.compile(Onibi::Parser.parse("(ab)"))[:graph]
    actions = graph[:start_edges].flat_map { |edge| edge[:actions] } + graph[:edges].flat_map { |edge| edge[:actions] }
    assert_equal %i[CAPTURE_OPEN CAPTURE_CLOSE], actions.map { |action| action[:op] }
    assert_equal [0, 1], actions.map { |action| action[:slot] }
  end

  def test_vm_enforces_counted_repeat_bounds
    regexp = Onibi::Regexp.new("\\Aa{2,3}\\z")
    assert regexp.vm_match?("aa")
    assert regexp.vm_match?("aaa")
    refute regexp.vm_match?("aaaa")
  end

  def test_compiler_allocates_distinct_counter_slots_for_repeats
    graph = Onibi::Compiler.compile(Onibi::Parser.parse("a{1,2}b{1,2}"))[:graph]
    assert_equal 2, graph[:counter_count]
    slots = graph[:edges].flat_map { |edge| edge[:actions] }
      .select { |action| action[:op].to_s.start_with?("COUNTER", "TEST_COUNTER") }
      .map { |action| action[:slot] }.uniq
    assert_equal [0, 1], slots.sort
  end

  def test_vm_rejects_invalid_subject_encoding
    invalid = [0xff].pack("C").force_encoding(Encoding::UTF_8)
    assert_raises(ArgumentError) { Onibi::Regexp.new(".").vm_match?(invalid) }
    assert_raises(ArgumentError) { Onibi::Regexp.new(".").vm_match_result(invalid) }
  end

  def test_vm_keeps_required_suffix_after_nullable_prefix
    optional = Onibi::Regexp.new("a?b")
    repeated = Onibi::Regexp.new("a*b")
    refute optional.vm_match?("a")
    refute repeated.vm_match?("aa")
    assert optional.vm_match?("b")
    assert repeated.vm_match?("aab")
  end

  def test_nullable_capture_uses_mri_until_tag_history_exists
    regexp = Onibi::Regexp.new("(a*)")
    refute regexp.program_cached?
    assert_equal Regexp.new("(a*)").match("aa").to_a, regexp.match("aa").to_a
    assert_equal({ 1 => { start: 0, end: 2 } }, regexp.vm_match_result("aa")[:captures])
  end

  def test_compiler_assigns_distinct_capture_slots
    graph = Onibi::Compiler.compile(Onibi::Parser.parse("(a(b))"))[:graph]
    actions = graph[:start_edges].flat_map { |edge| edge[:actions] } + graph[:edges].flat_map { |edge| edge[:actions] }
    assert_equal [0, 2, 3, 1], actions.map { |action| action[:slot] }
  end

  def test_tagged_vm_materializes_nested_captures
    result = Onibi::Regexp.new("(a(b))").vm_match_result("xxabbxx")
    assert_equal({ start: 2, end: 4 }, result.slice(:start, :end))
    assert_equal({ 1 => { start: 2, end: 4 }, 2 => { start: 3, end: 4 } }, result[:captures])
  end

  def test_backreference_has_explicit_dynamic_pipeline_nodes
    tokens = Onibi::Lexer.new("(a)\\1").tokens
    assert_equal :backref, tokens.last[:kind]
    ast = Onibi::Parser.parse("(a)\\1")[:ast]
    assert_equal :backref, ast[:children].last[:type]
    assert_equal 1, ast[:children].last[:capture]
    graph = Onibi::Compiler.compile(Onibi::Parser.parse("(a)\\1"))[:graph]
    assert_includes graph[:states].map { |state| state[:op] }, :G_BACKREF
  end

  def test_dynamic_vm_executes_numeric_backreference
    regexp = Onibi::Regexp.new("(a)\\1")
    assert regexp.vm_match?("xxaaxx")
    refute regexp.vm_match?("xxabxx")
    assert_equal({ start: 2, end: 4, captures: { 1 => { start: 2, end: 3 } } }, regexp.vm_match_result("xxaaxx"))
  end

  def test_dynamic_vm_casefolds_ascii_backreference
    regexp = Onibi::Regexp.new("(a)\\1", 1)
    assert regexp.vm_match?("aA")
    refute regexp.vm_match?("ab")
  end

  def test_named_backreference_is_one_lexer_token
    token = Onibi::Lexer.new("(a)\\k<x>").tokens.last
    assert_equal :backref, token[:kind]
    assert_equal "x", token[:name]
    ast = Onibi::Parser.parse("(a)\\k<x>")[:ast]
    assert_equal :backref, ast[:children].last[:type]
    assert_equal "x", ast[:children].last[:name]
    graph = Onibi::Compiler.compile(Onibi::Parser.parse("(?<x>a)\\k<x>"))[:graph]
    assert_equal 1, graph[:states][1][:payload][:capture]
    assert_raises(Onibi::RegexpError) { Onibi::Parser.parse("(?<1x>a)") }
  end

  def test_named_backreference_executes_in_dynamic_vm
    regexp = Onibi::Regexp.new("(?<x>a)\\k<x>")
    assert regexp.vm_match?("xxaaxx")
    refute regexp.vm_match?("xxabxx")
    assert_equal({ start: 2, end: 4, captures: { 1 => { start: 2, end: 3 } } }, regexp.vm_match_result("xxaaxx"))
  end

  def test_vm_dispatcher_executes_rseq_by_execution_class
    regular = Onibi::RSeq.lower(Onibi::Compiler.compile(Onibi::Parser.parse("abc")))
    tagged = Onibi::RSeq.lower(Onibi::Compiler.compile(Onibi::Parser.parse("(abc)")))
    dynamic = Onibi::RSeq.lower(Onibi::Compiler.compile(Onibi::Parser.parse("(a)\\1")))
    assert Onibi::VM.execute(regular, "xxabcxx", :REGULAR_FAST)
    assert Onibi::VM.execute(tagged, "xxabcxx", :TAGGED_ORDERED)
    assert Onibi::VM.execute(dynamic, "xxaaxx", :DYNAMIC)
    assert_raises(ArgumentError) { Onibi::VM.execute(regular, "abc", :UNKNOWN) }
    assert_raises(ArgumentError) { Onibi::VM.execute(regular.merge(blob: "bad"), "abc", :REGULAR_FAST) }
    inconsistent = regular.merge(header: regular[:header].merge(state_count: 99))
    assert_raises(ArgumentError) { Onibi::VM.execute(inconsistent, "abc", :REGULAR_FAST) }
  end

  def test_regexp_compiles_pipeline_once_at_initialize
    regexp = Onibi::Regexp.new("abc")
    assert regexp.program_cached?
    assert regexp.program_frozen?
    assert_operator regexp.program_size, :>, regexp.source.bytesize
    assert_same regexp.pipeline, regexp.pipeline
    assert_same regexp.pipeline[:tokens], regexp.pipeline[:parsed][:tokens]
    canonical = regexp.pipeline[:canonical]
    assert_same regexp.pipeline[:parsed][:ast], canonical[:ast]
    assert_same regexp.pipeline[:compiled][:graph], canonical[:gir]
    assert_same regexp.pipeline[:rseq_program], canonical[:rseq]
    refute Onibi::Regexp.new("(?=\\d)b").program_cached?
    refute Onibi::Regexp.new("(?=\\d)b").program_frozen?
  end

  def test_ignorecase_is_compiled_into_rseq_header
    regexp = Onibi::Regexp.new("ABC", 1)
    assert regexp.program_cached?
    assert regexp.vm_match?("xxabcxx")
    refute regexp.vm_match?("xxabDxx")
    rseq = Onibi::RSeq.lower(Onibi::Compiler.compile(Onibi::Parser.parse("ABC", 1)))
    assert_equal true, rseq[:header][:ignorecase]
    assert_predicate Onibi::Parser.parse("ABC", 1)[:options].first, :frozen?
    class_regexp = Onibi::Regexp.new("[a-z]", 1)
    assert class_regexp.vm_match?("Q")
  end

  def test_non_ascii_pattern_stays_on_mri_until_encoding_lowering_exists
    regexp = Onibi::Regexp.new("あ")
    refute regexp.program_cached?
    assert regexp.match?("あ")
  end

  def test_vm_polls_pending_thread_interrupts
    regexp = Onibi::Regexp.new("a")
    worker = Thread.new { regexp.vm_match?("b" * 20_000_000) }
    worker.report_on_exception = false
    Thread.pass
    worker.raise(Interrupt)
    assert_raises(Interrupt) { worker.value }
  end

  def test_multiline_anchors_are_compiled_into_line_assertions
    regexp = Onibi::Regexp.new("^a$", 4)
    assert regexp.vm_match?("x\na\nx")
    refute regexp.vm_match?("x\nba\nx")
    graph = Onibi::Compiler.compile(Onibi::Parser.parse("^a$", 4))[:graph]
    assert_equal :ASSERT_BEGIN_LINE, graph[:start_edges].first[:actions].first[:op]
    assert_equal :ASSERT_END_LINE, graph[:edges].last[:actions].first[:op]
  end

  def test_posix_class_is_a_semantic_token_and_vm_predicate
    tokens = Onibi::Lexer.new("[[:alpha:]]").tokens
    assert_equal %i[class_start posix_class class_end], tokens.map { |token| token[:kind] }
    assert_equal "alpha", tokens[1][:name]
    regexp = Onibi::Regexp.new("[[:alpha:]]")
    assert regexp.vm_match?("xxB")
    refute regexp.vm_match?("222")
    assert_predicate tokens[1][:name], :frozen?
    assert_raises(Onibi::RegexpError) { Onibi::Parser.parse("[[:bogus:]]") }
  end

  def test_word_boundary_assertions_are_compiled
    regexp = Onibi::Regexp.new("\\bcat\\b")

    assert regexp.program_cached?
    assert regexp.vm_match?("a cat naps")
    refute regexp.vm_match?("scatter")
    actions = regexp.pipeline[:compiled][:graph][:edges].flat_map { |edge| edge[:actions] }
    assert_includes actions.map { |action| action[:op] }, :ASSERT_WORD_BOUNDARY
  end

  def test_search_origin_anchor_is_an_edge_assertion
    regexp = Onibi::Regexp.new("\\Ga")
    assert regexp.program_cached?
    assert regexp.vm_match?("a")
    refute regexp.vm_match?("ba")
    assert_equal :ASSERT_SEARCH_ORIGIN,
                 regexp.pipeline[:compiled][:graph][:start_edges].first[:actions].first[:op]
  end

  def test_match_reset_is_a_semantic_parser_node
    ast = Onibi::Parser.parse("prefix\\Ksuffix")[:ast]

    assert_equal :match_reset, ast[:children][6][:type]
    regexp = Onibi::Regexp.new("prefix\\Ksuffix")
    assert regexp.program_cached?
    assert_equal({ start: 8, end: 14 }, regexp.vm_match_result("xxprefixsuffixzz"))
  end

  def test_capture_tokens_and_execution_class
    regexp = Onibi::Regexp.new("(abc)")
    assert_equal :TAGGED_ORDERED, regexp.pipeline[:interpreter]
    assert_equal(%i[group_start literal literal literal group_end], regexp.pipeline[:tokens].map { |token| token[:kind] })
    actions = regexp.pipeline[:gir_graph][:edges].flat_map { |edge| edge[:actions] }
    assert_equal(%i[CAPTURE_OPEN CAPTURE_CLOSE], actions.map { |action| action[:op] })
    assert_equal({ 1 => { start: 2, end: 5 } }, regexp.vm_match_result("xxabcxx")[:captures])
    assert_equal({ id: 1, use: :CAPTURE_OUTPUT_ONLY, slots: [2, 3] }, regexp.pipeline[:captures].first)
    assert regexp.match?("xxabcxx")
    refute regexp.match?("xxabxx")
    assert_equal(%i[CAPTURE_OPEN STRING CAPTURE_CLOSE], regexp.pipeline[:rseq_compact].map { |op| op[:op] })
  end
end
