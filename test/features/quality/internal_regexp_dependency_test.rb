# frozen_string_literal: true

require "test_helper"

class InternalRegexpDependencyTest < Minitest::Test
  LIBRARY_PATH = File.join(PROJECT_ROOT, "lib")
  EXTENSION_SOURCE = File.join(PROJECT_ROOT, "ext", "onibi", "onibi.c")

  # Read the same implementation files that the amalgamated build reads.
  # This keeps the structural checks tied to the build dependency order.
  def extension_manifest
    File.foreach(EXTENSION_SOURCE).filter_map do |line|
      line[/^\s*#include\s+"([^"]+\.c)"\s*$/, 1]
    end
  end

  def extension_source
    extension_manifest.map do |file|
      path = File.join(File.dirname(EXTENSION_SOURCE), file)
      raise "missing implementation included by #{EXTENSION_SOURCE}: #{file}" unless File.file?(path)

      File.read(path)
    end.join("\n").gsub(/\bstatic\s+([A-Za-z_][A-Za-z0-9_ ]*)\n\s*/, 'static \\1 ')
  end

  def source_for(*files)
    files.map do |file|
      path = File.join(File.dirname(EXTENSION_SOURCE), file)
      raise "missing implementation included by #{EXTENSION_SOURCE}: #{file}" unless File.file?(path)

      File.read(path)
    end.join("\n")
  end

  def test_library_matching_does_not_use_mri_regexp_operators
    source = Dir[File.join(LIBRARY_PATH, "**", "*.rb")].map { |file| File.read(file) }.join

    refute_includes source, "=~"
    refute_includes source, "/\\s/"
    refute_includes source, "/[A-Za-z0-9_]/"
  end

  def test_native_pipeline_objects_are_not_public_ruby_constants
    refute_includes Onibi.constants(false), :Lexer
    refute_includes Onibi.constants(false), :Parser
    refute_includes Onibi.constants(false), :Compiler
    refute_includes Onibi.constants(false), :VM
    refute_includes Onibi.constants(false), :IRGen
    refute_includes Onibi.constants(false), :AST
    assert_includes Onibi.constants(false), :Regexp
  end

  def test_internal_pipeline_state_is_not_public_api
    internal_methods = %i[tokens ast gir rseq parsed compiled vm graph bytecode_program]

    internal_methods.each do |name|
      refute_includes Onibi::Regexp.instance_methods(false), name
      refute_includes Onibi::Regexp.singleton_methods(false), name
    end
  end

  def test_tokenizer_cleanup_is_exception_safe
    source = extension_source
    initialize = source[/static VALUE onibi_initialize\(.*?\n}\n/m]

    refute_nil initialize
    assert_includes initialize, "rb_protect(onibi_tokenize_protected"
    assert_includes initialize, "onibi_token_vector_free(&tokens)"
    assert_includes initialize, "rb_jump_tag(tokenize_state)"
  end

  def test_regexp_state_owns_exact_ruby_values_and_marks_each_value
    source = source_for("onibi_common.c")
    regexp_struct = source[/struct onibi_regexp_t \{[^}]*\};/m]
    marker = source[/static void\s+onibi_mark\(.*?\n}\n/m]

    refute_nil regexp_struct
    refute_nil marker
    assert_equal %w[regexp source rseq rseq_blob names named_captures],
                 regexp_struct.scan(/VALUE\s+(\w+);/).flatten
    %w[regexp source rseq rseq_blob names named_captures].each do |name|
      assert_includes marker, "rb_gc_mark(obj->#{name});"
    end
  end

  def test_option_payload_survives_gc_stress_during_token_materialization
    previous_stress = GC.stress
    GC.stress = true
    source = Array.new(16, "(?im-mx:a)").join

    assert Onibi::Regexp.new(source).match?("A" * 16)
  ensure
    GC.stress = previous_stress
  end

  def test_ast_arena_is_released_after_building_the_published_program
    source = source_for("rseq.c")
    build = source[/static VALUE\s+onibi_build_program\(.*?\n}\n/m]

    refute_nil build
    assert_includes build, "onibi_ast_arena_free(&onibi_parsed_get(parsed)->arena)"
  end

  def test_native_matching_keeps_public_api_at_the_boundary
    assert Onibi::Regexp.new("^a$").match?("a")
    assert Onibi::Regexp.new("(?=a)a").match?("a")
    assert Onibi::Regexp.new("(?<=a)b").match?("ab")
    assert_equal [1, 2], Onibi::Regexp.new("a").match("ba").offset(0)
  end

  def test_supported_space_and_word_escapes_use_native_matcher
    assert Onibi::Regexp.new("\\s").match?(" ")
    assert Onibi::Regexp.new("\\s").match?("\n")
    assert Onibi::Regexp.new("\\w+").match?("word_2026")
    refute Onibi::Regexp.new("\\w").match?("é")
  end
end
