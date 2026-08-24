# frozen_string_literal: true

require "test_helper"

class MatchApiTest < Minitest::Test
  def test_match_and_match_question_use_compiler_vm
    regexp = Onibi::Regexp.new("cat")

    assert regexp.match?("xxcatyy")
    match = regexp.match("xxcatyy")
    assert_equal "cat", match[0]
    assert_equal 2, match.begin(0)
    refute regexp.match?("dog")
  end

  def test_match_position_uses_input_length_for_negative_positions
    regexp = Onibi::Regexp.new("a")

    assert_equal [1, 2], regexp.match("ba", -1).offset(0)
    assert_nil regexp.match("a", -2)
    assert_nil regexp.match("a", 2)
  end

  def test_match_position_rejects_string_like_mri
    assert_raises(TypeError) { Regexp.new("a").match("ba", "1") }
    assert_raises(TypeError) { Onibi::Regexp.new("a").match("ba", "1") }
    assert_equal "no implicit conversion from nil to integer",
                 assert_raises(TypeError) { Onibi::Regexp.new("a").match("ba", nil) }.message
  end

  def test_match_uses_mri_string_conversion_rules
    string_like = Object.new
    string_like.define_singleton_method(:to_str) { "ba" }

    assert_equal ["a"], Onibi::Regexp.new("a").match(string_like).to_a
    assert_nil Onibi::Regexp.new("a").match(nil)
    assert_nil Onibi::Regexp.new("a").match(:symbol)
    assert_raises(TypeError) { Onibi::Regexp.new("a").match(nil, "1") }
    assert_raises(TypeError) { Onibi::Regexp.new("a").match(1) }
  end

  def test_empty_pattern_uses_mri_position_rules
    regexp = Onibi::Regexp.new("")

    assert_nil regexp.match("", -1)
    assert_equal [1, 1], regexp.match("a", 1).offset(0)
    assert_equal [1, 1], regexp.match("a", 10).offset(0)
    assert_nil Onibi::Regexp.new("^").match("", 1)
  end

  def test_nullable_pattern_uses_mri_position_rules
    regexp = Onibi::Regexp.new("a*")

    assert_equal [0, 0], regexp.match("", 10).offset(0)
    assert_equal [1, 1], regexp.match("a", 10).offset(0)
  end

  def test_match_question_rejects_positions_past_input_end
    assert Regexp.new("a*").match("a", 10)
    assert Onibi::Regexp.new("a*").match("a", 10)
    refute Regexp.new("a*").match?("a", 10)
    refute Onibi::Regexp.new("a*").match?("a", 10)
  end

  def test_zero_width_lookbehind_rejects_positions_past_input_end
    match = Onibi::Regexp.new("(?<=a)").match("ba", 99)

    assert_nil match
  end

  def test_lookbehind_captures_are_returned_by_the_vm
    match = Onibi::Regexp.new("(?<=(ab))c").match("abc")

    assert_equal "c", match[0]
    assert_equal ["ab"], match.captures
    assert_equal 0, match.begin(1)
  end

  def test_named_captures_define_the_public_capture_indexes
    match = Onibi::Regexp.new("(?<name>(a))(b)").match("ab")

    assert_equal %w[ab a], match.to_a
    assert_equal "a", match["name"]
    assert_nil match[2]
  end

  def test_duplicate_named_captures_use_the_last_named_value
    match = Onibi::Regexp.new("(?<name>a)(?<name>b)").match("ab")

    assert_equal "b", match["name"]
  end

  def test_vm_preserves_ordered_choice_and_repeat_priority
    assert_equal "éa", Onibi::Regexp.new("éa+|é").match("éa")[0]
    assert_equal "aa", Onibi::Regexp.new("a?a+|a?").match("aa")[0]
    assert_equal "a", Onibi::Regexp.new("(?<!b)a|(?<!b)").match("a")[0]
  end

  def test_vm_uses_unicode_word_boundaries
    match = Onibi::Regexp.new(".\\b").match("aé")

    assert_equal "é", match[0]
    assert_equal 1, match.begin(0)
  end

  def test_captures_and_names_come_from_vm_result
    match = Onibi::Regexp.new("(?<word>[a-z]+)-\\k<word>").match("echo-echo")

    assert_equal "echo", match["word"]
    assert_equal ["echo"], match.captures
  end

  def test_scan_and_gsub_use_the_same_vm_match_path
    regexp = Onibi::Regexp.new("a+")

    assert_equal %w[aaa aa], regexp.scan("xxaaayzaa")
    assert_equal "xxXyzX", regexp.gsub("xxaaayzaa", "X")
  end

  def test_scan_returns_captures_for_conditional_groups
    pattern = "(a)?(?(1)b|c)"
    expected = "ababa".scan(::Regexp.new(pattern))
    actual = Onibi::Regexp.new(pattern).scan("ababa")

    assert_equal expected, actual
  end

  def test_options_assertions_and_unicode_are_executed_by_the_vm
    assert Onibi::Regexp.new("^cat$", Onibi::Regexp::MULTILINE).match?("cat")
    assert Onibi::Regexp.new("(?=cat)cat").match?("cat")
    assert Onibi::Regexp.new("é", Onibi::Regexp::FIXEDENCODING).match?("xxéyy")
  end

  def test_bytecode_program_is_compiler_output
    regexp = Onibi::Regexp.new("ab+")
    program = regexp.send(:bytecode_program)

    assert_instance_of Onibi::IRGen::YARVIR::Program, program
    assert_equal [2, 5], Onibi::IRGen::YARVIR.execute(program, "xxabbyy", 0)
    refute_instance_of Onibi::AST::Sequence, program.flags[:semantic_root]
  end
end
