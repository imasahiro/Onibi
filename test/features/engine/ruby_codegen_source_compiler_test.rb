# frozen_string_literal: true

require "test_helper"

class RubyCodegenSourceCompilerTest < Minitest::Test
  def test_generated_program_executes_a_typed_literal_emitter
    value = "quote \"; sentinel = :unchanged; # newline\n"
    program = Onibi::Codegen::GeneratedProgram.literal(value)
    assert_equal Onibi::Codegen::RubyEmitter.literal(value), Onibi::Codegen::RubyGenerator.literal(value)

    assert_equal true, program.search(value, 0, capture: false)
    assert_equal [0, value.length, []], program.search(value, 0, capture: true)
    assert_equal false, program.search("different", 0, capture: false)
    assert_equal "__onibi_search", program.entrypoint.to_s
  end

  def test_compiler_uses_anonymous_module_and_rejects_invalid_source
    source = "def self.__onibi_search(input, position, capture); true; end"
    program = Onibi::Codegen::GeneratedProgram.new(source)

    assert_kind_of Module, program.compiled_module
    refute program.compiled_module.name
    assert_equal true, program.search("anything", 0, capture: false)

    assert_raises(Onibi::CodegenError) do
      Onibi::Codegen::GeneratedProgram.new("def self.__onibi_search(")
    end
  end

  def test_source_compiler_does_not_require_rubyvm_instruction_sequence
    refute Onibi::Codegen::SourceCompiler.production_requires_rubyvm?
    assert Onibi::Codegen::SourceCompiler.available?
  end
end
