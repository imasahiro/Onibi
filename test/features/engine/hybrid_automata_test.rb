# frozen_string_literal: true

require_relative "../../test_helper"

class HybridAutomataTest < Minitest::Test
  def test_builds_one_hybrid_program_with_fused_transition_components
    program = compile("BEGIN(?:[a-z]+|[0-9]{2,4})END")

    assert_equal :hybrid, program.engine_kind
    assert_equal :cfg, program.input_ir
    assert_equal "BEGIN", program.prefix_literal
    assert_includes program.components, :string_matching
    assert_includes program.components, :lazy_dfa
    assert_includes program.components, :bit_parallel_nfa
    assert_equal %i[string_search dfa_lookup nfa_transition accept], program.bytecode.map(&:opcode)
  end

  def test_sparse_prefix_with_trailing_literal_materializes_static_dfa
    program = compile("BEGIN(?:[a-z]+|[0-9]{2,4})END")

    refute program.match?("x" * 65_536)
    assert_equal 65_536, program.send(:prefix_literal_candidate, "#{"x" * 65_536}BEGIN", 0)
  end

  def test_builds_candidate_event_stream_for_wide_ascii_first_sets
    program = compile("[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+")
    input = "user.name+tag@example.com"

    events = program.send(:candidate_search_input, input)

    refute_nil events
    assert_equal 0, events.getbyte(0)
    assert_equal "@".ord, events.getbyte(input.index("@"))
    assert_nil program.send(:candidate_search_input, "#{input}\0")
  end

  def test_specialized_program_skips_generic_topology
    specialized = compile("needle")
    generic = compile("(?:ab|a[0-9])+z")

    assert_equal 0, specialized.topology_state_count
    assert_operator generic.topology_state_count, :>, 0
  end

  def test_matches_supported_regular_subset_like_mri
    patterns = [
      "", "abc", "cat|dog|mouse", "a[0-9]+z", "colou?r", "(?:ab)+c",
      "a{2,4}b", "x.*y", "BEGIN.{0,8}END", "[^x]{1,3}END", "\\d+X"
    ]
    inputs = [
      "", "abc", "xxdogyy", "a123z", "color", "colour", "abababc",
      "aaab", "x---y", "BEGIN1234END", "aaaEND", "99X", "no match", "x\ny"
    ]
    patterns.product(inputs).each do |pattern, input|
      expected = ::Regexp.new(pattern).match?(input)
      program = compile(pattern)
      assert_equal expected, program.match?(input), "bytecode /#{pattern}/ against #{input.inspect}"
    end
  end

  def test_matches_exhaustive_short_inputs_like_mri
    patterns = ["a|bc", "a*b", "(?:ab|c)+d?", "[ab]{0,3}c", ".+b"]
    inputs = [""] + (1..5).flat_map { |length| %w[a b c].repeated_permutation(length).map(&:join) }

    patterns.each { |pattern| assert_exhaustive_pattern(pattern, inputs) }
  end

  def test_honors_search_position
    program = compile("abc")

    assert program.match?("abc---abc", 4)
    refute program.match?("abc---", 4)
    assert program.match?("abc", -3)
  end

  def test_word_boundary_literal_uses_string_search_with_boundary_checks
    program = compile("\\bcat\\b")

    assert_equal [2, 5, []], program.match_result("a cat naps")
    assert_equal [12, 15, []], program.match_result("concatenate cat")
    refute program.match?("concatenate")
  end

  def test_positive_prefix_literal_uses_direct_prefix_search
    program = compile("(?<=pre)fix")

    assert_equal [3, 6, []], program.match_result("prefix")[0..2]
    assert program.match?("prefix")
    refute program.match?("suffix")
  end

  def test_negative_prefix_literal_uses_direct_prefix_search
    program = compile("(?<!un)happy")

    assert_equal [5, 10, []], program.match_result("very happy")[0..2]
    refute program.match?("unhappy")
    assert program.match?("happy")
  end

  def test_unbounded_possessive_literal_uses_suffix_search
    program = compile("a++b")

    assert_equal [1, 5, []], program.match_result("zaaab")[0..2]
    refute program.match?("zaaac")
  end

  def test_plain_unicode_literal_uses_direct_search
    program = compile("こんにちは")

    assert program.match?("挨拶はこんにちはです")
    refute program.match?("挨拶はさようならです")
  end

  def test_promotes_observed_nfa_subsets_to_bounded_dfa_states
    hybrid = compile("(?:ab|ac)+z")
    nfa_only = Onibi::HybridAutomata.compile("(?:ab|ac)+z", dfa: false, string_matching: false)

    3.times { hybrid.match?("xxabacabacz") }
    assert_operator hybrid.dfa_state_count, :>, 0
    assert_equal 0, nfa_only.dfa_state_count
    assert_equal nfa_only.match?("xxabacabacz"), hybrid.match?("xxabacabacz")
  end

  def test_compilation_unit_is_the_backend_input
    ast = Onibi::Parser.new("a[0-9]+z").parse
    unit = Onibi::HybridAutomata::Optimization.compile_prepared(ast, [], Encoding::US_ASCII)
    program = Onibi::HybridAutomata.compile_unit(unit)

    assert_equal :cfg, program.input_ir
    assert program.match?("a123z")
    refute program.match?("a123x")
  end

  def test_cfg_operation_graph_can_drive_hfa_topology
    ast = Onibi::Parser.new("abc[0-9]+z").parse
    unit = Onibi::HybridAutomata::Optimization.compile_prepared(ast, [], Encoding::US_ASCII)
    program = Onibi::HybridAutomata.compile_unit(unit)

    assert_equal :cfg, program.input_ir
    assert program.match?("abc123z")
    refute program.match?("abc123x")
  end

  def test_cfg_choice_graph_can_drive_hfa_topology
    ast = Onibi::Parser.new("cat|dog").parse
    unit = Onibi::HybridAutomata::Optimization.compile_prepared(ast, [], Encoding::US_ASCII)
    program = Onibi::HybridAutomata.compile_unit(unit)

    assert program.match?("a dog")
    refute program.match?("a fox")
  end

  def test_capture_groups_are_regular_language_nodes_for_match_only_hfa
    program = Onibi::HybridAutomata.compile("(?<word>[a-z]+)-([0-9]+)")

    assert program.match?("item-2026")
    refute program.match?("item-")
  end

  def test_supports_ascii_properties_and_global_options
    property = Onibi::HybridAutomata.compile("\\p{Alpha}+")
    insensitive = Onibi::HybridAutomata.compile("case", options: ["ignorecase"])
    multiline = Onibi::HybridAutomata.compile("a.b", options: ["multiline"])

    assert property.match?("letters")
    assert insensitive.match?("CASE")
    assert multiline.match?("a\nb")
  end

  def test_unicode_class_scans_past_nonmatching_prefix
    program = Onibi::HybridAutomata.compile("[あ-こ]+")

    assert program.match?("xyzかきく")
    refute program.match?("xyz")
  end

  def test_unicode_run_returns_byte_offsets
    program = Onibi::HybridAutomata.compile("\\p{Hiragana}+")

    assert_equal [3, 12, []], program.match_result("xyzかきく")
    assert_nil program.match_result("xyz")
  end

  def test_unicode_class_scans_a_long_input_linearly
    program = Onibi::HybridAutomata.compile("\\p{Hiragana}+")

    assert_equal [0x3040, 0x309f], program.instance_variable_get(:@unicode_range)
    assert program.match?("#{"漢字" * 500}ひらがな")
  end

  def test_unicode_letter_and_word_runs_use_codepoint_fast_paths
    letter = Onibi::HybridAutomata.compile("\\p{Letter}+")
    word = Onibi::HybridAutomata.compile("[[:word:]]+")

    assert letter.match?("123日本語456")
    assert word.match?("記号-日本語_2026-終端")
  end

  def test_unicode_word_class_lowers_to_fast_word_matcher
    program = Onibi::HybridAutomata.compile("[[:word:]]+")

    assert_equal :word?, program.instance_variable_get(:@unicode_matcher)
    assert program.match?("—日本語—")
    refute program.match?("——")
  end

  def test_unicode_range_run_accepts_codepoint_iteration
    program = Onibi::HybridAutomata.compile("[ぁ-ん]+")

    assert program.match?("文字列ひらがな終端")
    refute program.match?("文字列カタカナ終端")
  end

  def test_ascii_unicode_property_uses_a_codepoint_range
    program = Onibi::HybridAutomata.compile("\\p{ASCII}+")

    assert_equal [0, 127], program.instance_variable_get(:@unicode_range)
    assert program.match?("abc日本語")
  end

  def test_ascii_ignorecase_literal_avoids_full_input_downcase
    program = Onibi::HybridAutomata.compile("case", options: ["ignorecase"])

    assert program.match?("a long prefix CASE suffix")
    refute program.match?("a long prefix cost suffix")
  end

  def test_literal_event_caches_its_first_byte
    program = Onibi::HybridAutomata.compile("needle")

    assert_equal "n", program.instance_variable_get(:@exact_first_byte)
  end

  def test_ignorecase_event_caches_case_variants
    program = Onibi::HybridAutomata.compile("case", options: ["ignorecase"])

    assert_equal %w[c C], program.instance_variable_get(:@casefold_variants)
    assert_equal "case", program.instance_variable_get(:@casefold_literal)
  end

  def test_ignorecase_keeps_unicode_case_folding
    program = Onibi::HybridAutomata.compile("k", options: ["ignorecase"])

    assert program.match?("K")
    assert Onibi::HybridAutomata.compile("s", options: ["ignorecase"]).match?("ſ")
    assert program.match?("xK", 1)
  end

  def test_repeated_literal_uses_literal_search
    program = Onibi::HybridAutomata.compile("(?:日本語)+")

    assert program.match?("開始日本語日本語終了")
    refute program.match?("開始英語終了")
  end

  def test_supports_word_boundary_events_at_pattern_edges
    program = Onibi::HybridAutomata.compile("\\bcat\\b")

    assert program.match?("a cat naps")
    refute program.match?("scatter")
    refute program.match?("catfish")
  end

  def test_negative_lookahead_uses_literal_candidate_events
    program = Onibi::HybridAutomata.compile("cat(?!fish)")

    assert program.match?("a cat naps")
    refute program.match?("a catfish swims")
  end

  def test_negative_suffix_literal_uses_direct_suffix_search
    program = compile("cat(?!fish)")

    assert_equal [2, 5, []], program.match_result("a cat naps")
    assert_equal [8, 11, []], program.match_result("catfish cat")
    refute program.match?("catfish")
  end

  def test_literal_dot_candidate_respects_multiline_option
    multiline = Onibi::HybridAutomata.compile("a.b", options: ["multiline"])
    regular = Onibi::HybridAutomata.compile("a.b")

    assert multiline.match?("a\nb")
    refute regular.match?("a\nb")
  end

  def test_literal_star_candidate_respects_dot_semantics
    program = Onibi::HybridAutomata.compile("a.*z")

    assert program.match?("a-middle-z")
    refute program.match?("a-middle\nz")
  end

  def test_lazy_literal_star_uses_first_suffix_candidate
    program = Onibi::HybridAutomata.compile("a.*?z")

    assert program.match?("a-first-z-second-z")
    refute program.match?("a-first\nz")
  end

  def test_supports_simple_numbered_backreferences
    program = Onibi::HybridAutomata.compile("([a-z]+)-\\1")

    assert program.match?("echo-echo")
    assert program.match?("prefix-echo-echo")
    refute program.match?("echo-item")
    refute program.match?("echo-foxtrot")
    refute program.match?("abca-bcd")

    insensitive = Onibi::HybridAutomata.compile("([a-z]+)-\\1", options: ["ignorecase"])
    assert insensitive.match?("Echo-ECHO")
  end

  def test_repeated_literal_run_uses_suffix_events
    program = Onibi::HybridAutomata.compile("a++b")

    assert program.match?("aaaaab")
    refute program.match?("aaaaac")
  end

  def test_bounded_literal_uses_minimum_run_search
    program = Onibi::HybridAutomata.compile("a{4,12}")

    assert program.match?("baaaaaaaac")
    refute program.match?("baaac")
  end

  def test_literal_alternation_uses_independent_candidates
    program = Onibi::HybridAutomata.compile("cat|dog|fox")

    assert program.match?("the quick fox")
    refute program.match?("the quick cow")
  end

  def test_fixed_width_repeated_alternation_exposes_a_suffix_event
    program = Onibi::HybridAutomata.compile("(?:ab|ac|ad|ba|bc|bd)+z")

    assert_equal %w[ab ac ad ba bc bd], program.repeated_alternation_literal_spec.branches
    assert_equal "z", program.repeated_alternation_literal_spec.suffix
    assert program.match?("xxabacbdz")
    refute program.match?("xxabacbdx")
  end

  def test_fixed_class_run_exposes_a_suffix_event
    program = Onibi::HybridAutomata.compile("a[bc]{4}z")

    refute_nil program.class_run_literal_spec
    assert_equal 4, program.class_run_literal_spec.minimum
    assert program.match?("xxabcbcz")
    refute program.match?("xxabcbcx")
  end

  def test_two_class_runs_expose_a_separator_event
    program = Onibi::HybridAutomata.compile("([a-z]+)-([0-9]+)")

    refute_nil program.class_run_chain_spec
    assert program.match?("xxitem-2026yy")
    refute program.match?("xxitem-yy")
  end

  def test_adjacent_class_runs_use_a_direct_boundary_event
    program = Onibi::HybridAutomata.compile("[a-z]+[0-9]+")

    refute_nil program.adjacent_class_run_spec
    assert program.match?("xxitem2026yy")
    refute program.match?("xxitemyyyy")
  end

  def test_three_class_runs_use_a_direct_boundary_event
    program = Onibi::HybridAutomata.compile("\\w+\\s+\\d+")

    refute_nil program.class_run_triple_spec
    assert program.match?("xxitem 2026yy")
    refute program.match?("xxitem-2026yy")
  end

  def test_three_class_runs_return_a_full_match_result
    program = Onibi::HybridAutomata.compile("\\w+\\s+\\d+")

    assert_equal [0, 11, []], program.match_result("xxitem 2026yy")
    assert_equal [[0, 11, []]], program.each_match_result("xxitem 2026yy").to_a
  end

  def test_literal_class_literal_chain_uses_suffix_events
    program = Onibi::HybridAutomata.compile("abc[0-9]+z")

    refute_nil program.literal_class_literal_spec
    assert program.match?("xxabc123zxx")
    refute program.match?("xxabcxyzxx")
  end

  def test_single_ascii_run_uses_a_table_scan
    program = Onibi::HybridAutomata.compile("[a-z]+")

    refute_nil program.ascii_run_spec
    assert_equal "abcdefghijklmnopqrstuvwxyz", program.ascii_run_spec.character_set
    assert program.match?("123abc456")
    refute program.match?("123456")
  end

  def test_single_byte_ascii_run_uses_string_index
    program = Onibi::HybridAutomata.compile("[x]+")

    assert_equal "x", program.ascii_run_spec.candidate_byte
    assert program.match?("123x456")
  end

  def test_single_byte_class_spec_caches_a_candidate_byte
    program = Onibi::HybridAutomata.compile("[x]")

    assert_equal "x", program.instance_variable_get(:@single_byte_spec).candidate_byte
  end

  def test_ascii_run_spec_caches_candidate_bytes
    program = Onibi::HybridAutomata.compile("[0-9]+")

    assert_equal 10, program.instance_variable_get(:@ascii_run_spec).candidate_bytes.length
  end

  def test_ascii_run_candidate_uses_the_earliest_cached_byte
    program = compile("[0-9]+")

    assert_equal [3, 6, []], program.match_result("abc123")
  end

  def test_ascii_property_tables_are_reused_across_compiles
    first = compile("\\p{Alpha}+")
    second = compile("\\p{Alpha}+")

    assert_same first.ascii_run_spec.table, second.ascii_run_spec.table
  end

  def test_single_dot_run_uses_a_newline_aware_table
    program = Onibi::HybridAutomata.compile(".+")

    refute_nil program.ascii_run_spec
    assert program.match?("---")
    refute program.match?("\n")
  end

  def test_multiline_single_dot_run_accepts_any_nonempty_input
    program = Onibi::HybridAutomata.compile(".+", options: ["multiline"])

    assert program.ascii_run_spec.any_byte
    assert program.match?("\n")
  end

  def test_ignorecase_class_run_keeps_casefolding
    program = Onibi::HybridAutomata.compile("[a-z]+", options: ["ignorecase"])

    assert program.match?("ABC")
  end

  def test_ignorecase_anchored_class_keeps_casefolding
    program = Onibi::HybridAutomata.compile("\\A[a-z]+\\z", options: ["ignorecase"])

    assert program.match?("ABC")
  end

  def test_atomic_prefix_subsumption_uses_equivalent_literal
    program = Onibi::HybridAutomata.compile("(?>a|ab)b")
    non_subsumed = Onibi::HybridAutomata.compile("(?>a|ab)c")

    assert program.match?("ab")
    refute program.match?("acb")
    refute non_subsumed.match?("abc")
  end

  def test_atomic_literal_caches_candidate_first_bytes
    program = Onibi::HybridAutomata.compile("(?>a|ab)c")

    assert_equal %w[a], program.instance_variable_get(:@atomic_literal_spec).candidate_bytes
  end

  def test_avoids_low_selectivity_single_byte_prefix_events
    program = compile("a[bc]{4}z")

    assert_nil program.prefix_literal
    assert program.match?("aabcbcz")
    refute program.match?("abcbx")
    refute program.match?(format("%<prefix>sax%<suffix>s", prefix: "x" * 64, suffix: "x" * 8))
  end

  def test_unanchored_search_can_start_from_a_sparse_first_byte
    program = Onibi::HybridAutomata.compile("a.b")

    assert program.match?("prefix aXb suffix")
    refute program.match?("prefix cXd suffix")
  end

  def test_unanchored_search_caches_multiple_first_bytes
    program = Onibi::HybridAutomata.compile("[cgt]gggtaaa|tttaccc[acg]")
    refute program.match?("xxxxxxxx")
    program.send(:static_first_bytes)

    assert_equal %w[c g t], program.instance_variable_get(:@static_first_bytes).bytes.sort.map(&:chr)
  end

  def test_first_byte_set_candidate_returns_earliest_match
    program = Onibi::HybridAutomata.compile("[cgt]x|[ab]y")
    first_bytes = "abcgt".b

    assert_equal 2, program.send(:first_byte_set_candidate, "xxc", 0, first_bytes)
  end

  def test_alternation_caches_required_literals_for_string_matching
    program = Onibi::HybridAutomata.compile("[cgt]gggtaaa|tttaccc[acg]")

    assert_equal([["gggtaaa", 1], ["tttaccc", 0]],
                 program.instance_variable_get(:@required_literals).map { |spec| [spec.literal, spec.offset] })
  end

  def test_required_literal_candidate_returns_earliest_branch_start
    program = Onibi::HybridAutomata.compile("[cgt]gggtaaa|tttaccc[acg]")

    assert_equal 3, program.send(:required_literal_candidate, "xxxcgggtaaa", 0)
  end

  def test_small_single_span_uses_static_dfa
    program = compile("a[bc]{4}z")
    assert program.match?("aabcbcz")
    refute program.match?("abcbx")
    assert program.match?(format("%saabcbcz", "x" * 64))
    assert program.instance_variable_get(:@static_dfa_data)
  end

  def test_dfa_cache_respects_its_state_limit
    program = Onibi::HybridAutomata.compile("(?:ab|ac|ba|bc)+z", dfa_state_limit: 2)
    program.match?("abacbabcabacx")
    assert_operator program.dfa_state_count, :<=, 2
  end

  def test_large_unprefixed_hfa_uses_bounded_static_dfa
    program = compile("(?:ab|ac|ad|ba|bc|bd)+z")
    assert program.instance_variable_get(:@static_dfa_data)
    assert_equal([true, false], %w[abacadbabcbdz abacadbabcbdx].map { |input| program.match?(input) })
  end

  def test_prefix_hfa_caches_trailing_literal
    program = compile("BEGIN(?:ab|ac|ad|ba|bc|bd)+z")

    assert_equal "z", program.instance_variable_get(:@trailing_literal)
    assert program.match?("BEGINabacadbabcbdz")
    refute program.match?("BEGINabacadbabcbdx")
  end

  def test_rejects_non_regular_or_capture_dependent_patterns
    ["a\\A"].each do |pattern|
      assert_raises(Onibi::HybridAutomata::UnsupportedPattern) { compile(pattern) }
    end
  end

  def test_supports_start_match_anchor
    program = compile("\\Gfoo")

    assert program.match?("xxfoo", 2)
    refute program.match?("xxfoo", 0)
    refute program.match?("xxfo", 2)
  end

  def test_supports_scoped_multiline_dot
    program = compile("(?m:.)")

    assert program.match?("\n")
    refute compile(".").match?("\n")
  end

  def test_supports_ascii_linebreak_escape
    program = compile("\\R")

    assert_equal [[1, 3, []], [1, 2, []]],
                 [program.match_result("x\r\ny"), program.match_result("x\ny")]
    refute program.match?("abc")
  end

  def test_supports_scoped_ignorecase_literals
    program = compile("(?i:cat)")

    assert program.match?("CAT")
    assert program.match?("xxcAtxx")
    refute program.match?("dog")
  end

  def test_supports_line_anchors
    start = compile("^foo")
    finish = compile("foo$")

    assert start.match?("bar\nfoo")
    refute start.match?("barfoo")
    assert finish.match?("foo\nbar")
    refute finish.match?("foobar")
  end

  def test_supports_a_leading_positive_lookahead
    program = compile("(?=a)a")

    assert program.match?("a")
    refute program.match?("b")
  end

  def test_supports_a_trailing_positive_lookahead
    program = compile("a(?=b)")

    assert program.match?("ab")
    refute program.match?("ac")
  end

  def test_accepts_non_ascii_inputs_for_byte_safe_ascii_patterns
    program = compile("[a-z]+")
    assert program.match?("café")
  end

  private

  def compile(pattern)
    Onibi::HybridAutomata.compile(pattern)
  end

  def assert_exhaustive_pattern(pattern, inputs)
    program = compile(pattern)
    regexp = ::Regexp.new(pattern)
    inputs.each do |input|
      assert_equal regexp.match?(input), program.match?(input), "/#{pattern}/ against #{input.inspect}"
    end
  end
end
