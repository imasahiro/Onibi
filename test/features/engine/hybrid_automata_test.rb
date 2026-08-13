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

  def test_hybrid_automaton_can_be_lowered_to_ruby_without_delegating_to_codegen
    program = compile("(?:ab|ac)+z")
    ruby = program.ruby_program

    assert_equal :hybrid_ruby, ruby.engine_kind
    assert_includes ruby.source, "__hfa_transition"
    refute_includes ruby.source, "GeneratedProgram"
    %w[abacacz xxabacz abax].each do |input|
      assert_equal program.match?(input), ruby.match?(input), input.inspect
    end
  end

  def test_never_falls_back_to_generated_ruby
    source = File.read(File.join(PROJECT_ROOT, "lib/onibi/hybrid_automata.rb"))

    refute_includes source, "GeneratedProgram"
    assert Onibi::HybridAutomata.compile("(?:ab|ac)+z").match?("xxabacz")
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
      ruby = program.ruby_program
      assert_equal expected, program.match?(input), "bytecode /#{pattern}/ against #{input.inspect}"
      assert_equal expected, ruby.match?(input), "ruby HFA /#{pattern}/ against #{input.inspect}"
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
    unit = Onibi::Codegen::Optimization.compile_prepared(ast, [], Encoding::US_ASCII)
    program = Onibi::HybridAutomata.compile_unit(unit)

    assert_equal :cfg, program.input_ir
    assert program.match?("a123z")
    refute program.match?("a123x")
  end

  def test_avoids_low_selectivity_single_byte_prefix_events
    program = compile("a[bc]{4}z")

    assert_nil program.prefix_literal
    assert program.match?("aabcbcz")
    refute program.match?("abcbx")
  end

  def test_dfa_cache_respects_its_state_limit
    program = Onibi::HybridAutomata.compile("(?:ab|ac|ba|bc)+z", dfa_state_limit: 2)

    program.match?("abacbabcabacx")
    assert_operator program.dfa_state_count, :<=, 2
  end

  def test_ruby_lowering_preserves_ablation_configuration
    program = Onibi::HybridAutomata.compile("needle", dfa: false, string_matching: false)
    ruby = program.ruby_program

    assert_equal program.components, ruby.components
    assert_equal program.match?("xneedle"), ruby.match?("xneedle")
    assert_equal program.match?("xneedles"), ruby.match?("xneedles")
  end

  def test_rejects_non_regular_or_capture_dependent_patterns
    ["(a)", "(a)\\1", "(?=a)a", "(?>a|ab)b", "\\Aabc", "(?i:a)"].each do |pattern|
      assert_raises(Onibi::HybridAutomata::UnsupportedPattern) { compile(pattern) }
    end
  end

  def test_rejects_non_ascii_inputs_in_the_poc
    program = compile("[a-z]+")

    assert_raises(Onibi::HybridAutomata::UnsupportedInput) { program.match?("café") }
  end

  private

  def compile(pattern)
    Onibi::HybridAutomata.compile(pattern)
  end

  def assert_exhaustive_pattern(pattern, inputs)
    program = compile(pattern)
    ruby = program.ruby_program
    regexp = ::Regexp.new(pattern)
    inputs.each do |input|
      assert_equal regexp.match?(input), program.match?(input), "/#{pattern}/ against #{input.inspect}"
      assert_equal regexp.match?(input), ruby.match?(input), "ruby /#{pattern}/ against #{input.inspect}"
    end
  end
end
