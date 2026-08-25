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

  def test_match_block_runs_once_and_returns_block_value
    calls = 0
    result = Onibi::Regexp.new("a").match("ba") do |matched|
      calls += 1
      matched[0].upcase
    end

    assert_equal 1, calls
    assert_equal "A", result
    assert_equal "a", Onibi::Regexp.last_match[0]
  end

  def test_match_data_match_rejects_negative_and_out_of_range_indexes
    matched = Onibi::Regexp.new("(?<x>a)(b)?").match("a")

    assert_raises(IndexError) { matched.match(-1) }
    assert_raises(IndexError) { matched.match(3) }
  end

  def test_tilde_clears_last_match_when_global_input_is_nil
    regexp = Onibi::Regexp.new("a")
    $_ = "a"
    $_ = nil

    assert_nil(~regexp)
    assert_nil(Onibi::Regexp.last_match)
  ensure
    $_ = nil
  end

  def test_case_equality_updates_last_match_state
    regexp = Onibi::Regexp.new("a")

    assert_equal true, regexp.public_send(:===, "ba")
    assert_equal ["a"], Onibi::Regexp.last_match.to_a
    assert_equal false, regexp.public_send(:===, "x")
    assert_nil Onibi::Regexp.last_match
  end

  def test_match_position_uses_input_length_for_negative_positions
    regexp = Onibi::Regexp.new("a")

    assert_equal [1, 2], regexp.match("ba", -1).offset(0)
    assert_nil regexp.match("a", -2)
    assert_nil regexp.match("a", 2)
  end

  def test_match_question_uses_string_length_not_overridden_length
    input_class = Class.new(String) do
      def length
        0
      end
    end
    input = input_class.new("ba")
    regexp = Onibi::Regexp.new("a")

    assert_equal Regexp.new("a").match?(input, 1), regexp.match?(input, 1)
    assert_equal Regexp.new("a").match?(input, 2), regexp.match?(input, 2)
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

  def test_match_uses_string_encoding_not_overridden_character_iteration
    input_class = Class.new(String) do
      def each_char
        raise "Regexp must not dispatch to String subclass each_char"
      end
    end
    input = input_class.new("a")

    assert_equal Regexp.new("a").match(input).to_a,
                 Onibi::Regexp.new("a").match(input).to_a
  end

  def test_match_uses_string_encoding_not_overridden_validation
    input_class = Class.new(String) do
      def valid_encoding?
        raise "Regexp must not dispatch to String subclass validation"
      end
    end
    input = input_class.new("é")

    assert_equal Regexp.new("é").match(input).to_a,
                 Onibi::Regexp.new("é").match(input).to_a
  end

  def test_match_uses_string_encoding_not_overridden_encoding
    input_class = Class.new(String) do
      def encoding
        raise "Regexp must not dispatch to String subclass encoding"
      end
    end
    input = input_class.new("a")

    assert_equal Regexp.new("a").match(input).to_a,
                 Onibi::Regexp.new("a").match(input).to_a
  end

  def test_match_data_uses_string_bytes_not_overridden_slicing
    input_class = Class.new(String) do
      def [](*)
        "bad"
      end

      def byteslice(*)
        "bad"
      end
    end
    input = input_class.new("ba")
    expected = Regexp.new("(a)").match(input)
    actual = Onibi::Regexp.new("(a)").match(input)

    assert_equal expected.to_a, actual.to_a
    assert_equal expected.pre_match, actual.pre_match
    assert_equal expected.post_match, actual.post_match
    assert_equal expected.byteoffset(1), actual.byteoffset(1)
  end

  def test_gsub_ignores_replacement_string_subclass_methods
    replacement_class = Class.new(String) do
      def gsub(*)
        "bad"
      end
    end
    replacement = replacement_class.new("\\1")

    expected = "a".gsub(::Regexp.new("(a)"), replacement)
    actual = Onibi::Regexp.new("(a)").gsub("a", replacement)

    assert_equal expected, actual
  end

  def test_empty_pattern_uses_mri_position_rules
    regexp = Onibi::Regexp.new("")

    assert_nil regexp.match("", -1)
    assert_equal [1, 1], regexp.match("a", 1).offset(0)
    assert_equal [1, 1], regexp.match("a", 10).offset(0)
    assert_equal [0, 0], Onibi::Regexp.new("^").match("", 1).offset(0)
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

  def test_nullable_assertions_run_at_input_end_for_large_positions
    assert_equal [1, 1], Onibi::Regexp.new("\\b").match("a", 99).offset(0)
    assert_equal [2, 2], Onibi::Regexp.new("(?<=a)").match("ba", 99).offset(0)
    assert_nil Onibi::Regexp.new("(?=a)").match("a", 99)
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

  def test_match_yields_and_returns_the_block_value
    result = Onibi::Regexp.new("a").match("ba") { |matched| [matched[0], matched.begin(0)] }

    assert_equal ["a", 1], result
    assert_nil Onibi::Regexp.new("z").match("a") { :unexpected }
  end

  def test_match_position_uses_mri_numeric_conversion_errors
    regexp = Onibi::Regexp.new("a")

    [Float::INFINITY, Float::NAN].each do |position|
      error = assert_raises(RangeError) { regexp.match("a", position) }

      assert_equal "float #{if position.infinite?
                              position.positive? ? "Inf" : "-Inf"
                            else
                              "NaN"
                            end} out of range of integer",
                   error.message
    end

    object = Object.new
    object.define_singleton_method(:to_int) { 1.2 }
    error = assert_raises(TypeError) { regexp.match("a", object) }

    assert_equal "can't convert Object to Integer (Object#to_int gives Float)", error.message
  end

  def test_scan_and_gsub_use_the_same_vm_match_path
    regexp = Onibi::Regexp.new("a+")

    assert_equal %w[aaa aa], regexp.scan("xxaaayzaa")
    assert_equal "xxXyzX", regexp.gsub("xxaaayzaa", "X")
  end

  def test_scan_and_gsub_ignore_string_subclass_overrides
    input_class = Class.new(String) do
      def length
        0
      end

      def [](*)
        "bad"
      end

      def encoding
        raise "scan/gsub must not dispatch to String subclass"
      end
    end
    input = input_class.new("ba")
    regexp = Onibi::Regexp.new("a")

    assert_equal ["a"], regexp.scan(input)
    assert_equal "bX", regexp.gsub(input, "X")
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
