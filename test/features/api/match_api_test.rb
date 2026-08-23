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
  end
end
