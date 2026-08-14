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
end
