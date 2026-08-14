# frozen_string_literal: true

require_relative "../../test_helper"

class HfaStandaloneFrontendTest < Minitest::Test
  def test_hfa_compile_does_not_require_codegen_namespace
    script = <<~RUBY
      require "onibi"
      abort if $LOADED_FEATURES.any? { |feature| feature.end_with?("/onibi/codegen.rb") }
      abort if defined?(Onibi::Codegen::GeneratedProgram)
      Onibi.send(:remove_const, :Codegen)
      program = Onibi::HybridAutomata.compile("a+")
      abort unless program.match?("aaa")
      regexp = Onibi::Regexp.new("a+")
      abort unless regexp.match?("aaa")
    RUBY

    assert system(RbConfig.ruby, "-Ilib", "-e", script)
  end

  def test_hfa_discards_alternation_branches_that_are_always_false
    {"a|(?!)|b" => %w[a b], "(?!)|foo" => ["foo"]}.each do |pattern, matches|
      regexp = Onibi::Regexp.new(pattern)
      %i[codegen_match? codegen_match codegen_each_result].each do |method|
        regexp.define_singleton_method(method) { |*| raise "unexpected codegen fallback" }
      end

      matches.each { |value| assert regexp.match?(value) }
      refute regexp.match?("c")
      assert_equal matches.first, regexp.match(matches.first).to_s
      assert_equal matches, regexp.scan(matches.join).map(&:to_s)
    end
  end

  def test_hfa_uses_direct_candidate_scan_for_bounded_sequences
    {"foo.{0,4}bar" => ["foo--bar", "foo\nbar"],
     "foo[a-z]{0,4}bar" => ["fooabbar", "foo--bar"]}.each do |pattern, (matching, rejected)|
      regexp = Onibi::Regexp.new(pattern)
      %i[codegen_match? codegen_match codegen_each_result].each do |method|
        regexp.define_singleton_method(method) { |*| raise "unexpected codegen fallback" }
      end
      regexp.define_singleton_method(:hfa_program) { raise "unexpected generic HFA program" }

      assert_equal matching, regexp.match(matching).to_s
      assert_equal [matching], regexp.scan(matching)
      refute regexp.match?(rejected)
    end
  end

  def test_hfa_handles_unicode_character_classes_without_codegen
    {"[\\p{Hiragana}]" => "あ", "[é]" => "é", "[\\u{1F600}]" => "😀"}.each do |pattern, input|
      regexp = Onibi::Regexp.new(pattern)
      %i[codegen_match? codegen_match codegen_each_result].each do |method|
        regexp.define_singleton_method(method) { |*| raise "unexpected codegen fallback" }
      end
      regexp.define_singleton_method(:hfa_program) { raise "unexpected generic HFA program" }

      assert regexp.match?(input)
      assert_equal input, regexp.match(input).to_s
      assert_equal [input], regexp.scan(input)
    end
  end

  def test_hfa_handles_unicode_full_fold_classes_without_codegen
    regexp = Onibi::Regexp.new("[ß]", "i")
    %i[codegen_match? codegen_match codegen_each_result].each do |method|
      regexp.define_singleton_method(method) { |*| raise "unexpected codegen fallback" }
    end
    regexp.define_singleton_method(:hfa_program) { raise "unexpected generic HFA program" }

    assert regexp.match?("SS")
    assert_equal "SS", regexp.match("SS").to_s
    assert_equal ["SS"], regexp.scan("SS")
  end

  def test_hfa_handles_nested_literal_capture_sequences_without_codegen
    regexp = Onibi::Regexp.new("(?<outer>(?<inner>é))(?<repeat>a)+(?<missing>b)?")
    %i[codegen_match? codegen_match codegen_each_result].each do |method|
      regexp.define_singleton_method(method) { |*| raise "unexpected codegen fallback" }
    end
    regexp.define_singleton_method(:hfa_program) { raise "unexpected generic HFA program" }

    assert regexp.match?("éaa")
    match = regexp.match("éaa")
    assert_equal "éaa", match.to_s
    assert_equal ["é", "é", "a", nil], match.captures
    assert_equal [["é", "é", "a", nil]], regexp.scan("éaa")
  end

  def test_hfa_handles_fixed_literal_backreferences_without_codegen
    regexp = Onibi::Regexp.new("(a)(b)\\1")
    %i[codegen_match? codegen_match codegen_each_result].each do |method|
      regexp.define_singleton_method(method) { |*| raise "unexpected codegen fallback" }
    end
    regexp.define_singleton_method(:hfa_program) { raise "unexpected generic HFA program" }

    assert regexp.match?("aba")
    match = regexp.match("aba")
    assert_equal "aba", match.to_s
    assert_equal ["a", "b"], match.captures
    assert_equal [["a", "b"]], regexp.scan("aba").map { |value| value }
  end

  def test_hfa_handles_repeated_literal_backreferences_without_codegen
    regexp = Onibi::Regexp.new("(a)+b\\1")
    %i[codegen_match? codegen_match codegen_each_result].each do |method|
      regexp.define_singleton_method(method) { |*| raise "unexpected codegen fallback" }
    end
    regexp.define_singleton_method(:hfa_program) { raise "unexpected generic HFA program" }

    assert regexp.match?("aaba")
    match = regexp.match("aaba")
    assert_equal "aaba", match.to_s
    assert_equal ["a"], match.captures
    assert_equal [["a"]], regexp.scan("aaba")
  end

  def test_hfa_handles_literal_lookahead_backreferences_without_codegen
    regexp = Onibi::Regexp.new("(?=(a))\\1")
    %i[codegen_match? codegen_match codegen_each_result].each do |method|
      regexp.define_singleton_method(method) { |*| raise "unexpected codegen fallback" }
    end
    regexp.define_singleton_method(:hfa_program) { raise "unexpected generic HFA program" }

    assert regexp.match?("a")
    match = regexp.match("a")
    assert_equal "a", match.to_s
    assert_equal ["a"], match.captures
    assert_equal [["a"]], regexp.scan("a")
  end

  def test_hfa_uses_generic_automaton_instead_of_codegen_for_generic_matches
    regexp = Onibi::Regexp.new("(a|b)c")
    %i[codegen_match? codegen_match codegen_each_result].each do |method|
      regexp.define_singleton_method(method) { |*| raise "unexpected codegen fallback" }
    end

    assert regexp.match?("bc")
    assert_equal "bc", regexp.match("bc").to_s
    assert_equal [["b"]], regexp.scan("bc")
  end

  def test_unsupported_match_does_not_fallback_to_codegen
    regexp = Onibi::Regexp.new("a(?=b)c")
    %i[codegen_match? codegen_match codegen_each_result].each do |method|
      regexp.define_singleton_method(method) { |*| raise "unexpected codegen fallback" }
    end

    assert_raises(Onibi::HybridAutomata::UnsupportedPattern) { regexp.match?("abc") }
    assert_raises(Onibi::HybridAutomata::UnsupportedPattern) { regexp.match("abc") }
    assert_raises(Onibi::HybridAutomata::UnsupportedPattern) { regexp.scan("abc") }
  end

  def test_hfa_handles_literal_absence_with_literal_suffix_without_codegen
    regexp = Onibi::Regexp.new("(?~real)ist")
    %i[codegen_match? codegen_match codegen_each_result].each do |method|
      regexp.define_singleton_method(method) { |*| raise "unexpected codegen fallback" }
    end
    regexp.define_singleton_method(:hfa_program) { raise "unexpected generic HFA program" }

    assert regexp.match?("realist")
    assert_equal "ealist", regexp.match("realist").to_s
    assert_equal ["ealist"], regexp.scan("realist")
  end
end
