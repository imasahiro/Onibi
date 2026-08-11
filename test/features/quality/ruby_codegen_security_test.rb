# frozen_string_literal: true

require_relative "../../test_helper"

class RubyCodegenSecurityTest < Minitest::Test
  def test_generated_source_rejects_dynamic_execution_primitives
    error = assert_raises(Onibi::CodegenError) do
      Onibi::Codegen::SourceCompiler.new.compile("RubyVM::InstructionSequence.compile(\"x\")")
    end

    assert_match(/forbidden operation/, error.message)
  end

  def test_generated_source_size_is_bounded
    error = assert_raises(Onibi::CodegenError) do
      Onibi::Codegen::Security.validate_source!("x" * 4, max_bytes: 3)
    end

    assert_match(/source_bytes/, error.message)
  end
end
