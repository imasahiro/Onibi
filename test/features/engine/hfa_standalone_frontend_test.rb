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
    regexp = Onibi::Regexp.new("a|(?!)|b")
    %i[codegen_match? codegen_match codegen_each_result].each do |method|
      regexp.define_singleton_method(method) { |*| raise "unexpected codegen fallback" }
    end

    assert regexp.match?("a")
    assert regexp.match?("b")
    refute regexp.match?("c")
    assert_equal "a", regexp.match("a").to_s
    assert_equal %w[a b], regexp.scan("ab").map(&:to_s)
  end
end
