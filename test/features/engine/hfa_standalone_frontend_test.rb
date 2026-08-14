# frozen_string_literal: true

require_relative "../../test_helper"

class HfaStandaloneFrontendTest < Minitest::Test
  def test_hfa_compile_does_not_require_codegen_namespace
    script = <<~RUBY
      require "onibi"
      abort if defined?(Onibi::Codegen::GeneratedProgram)
      Onibi.send(:remove_const, :Codegen)
      program = Onibi::HybridAutomata.compile("a+")
      abort unless program.match?("aaa")
      regexp = Onibi::Regexp.new("a+")
      abort unless regexp.match?("aaa")
    RUBY

    assert system(RbConfig.ruby, "-Ilib", "-e", script)
  end
end
