# frozen_string_literal: true

require "test_helper"

class CodegenLegacyRemovalTest < Minitest::Test
  LEGACY_FILES = %w[
    lib/onibi/bytecode.rb
    lib/onibi/alternation_compiler.rb
    lib/onibi/compiler_references.rb
    lib/onibi/compiler_quantifiers.rb
    lib/onibi/compiler.rb
    lib/onibi/virtual_machine_anchors.rb
    lib/onibi/virtual_machine.rb
    lib/onibi/matching_result.rb
    lib/onibi/ast_matcher.rb
    lib/onibi/ast_matcher_dispatch.rb
    lib/onibi/capture_matcher.rb
    lib/onibi/capture_matcher_dispatch.rb
    lib/onibi/capture_matcher_atoms.rb
    lib/onibi/capture_matcher_subexpressions.rb
    lib/onibi/capture_matcher_absence.rb
    lib/onibi/capture_matcher_linebreaks.rb
    lib/onibi/option_group_matchers.rb
    lib/onibi/dfa.rb
    lib/onibi/regexp_matching.rb
  ].freeze

  def test_legacy_execution_files_are_removed
    LEGACY_FILES.each do |relative_path|
      refute File.exist?(File.join(PROJECT_ROOT, relative_path)), relative_path
    end
  end

  def test_generator_handles_every_ast_node
    Onibi::AST.constants(false).each do |name|
      node_class = Onibi::AST.const_get(name)
      assert Onibi::Codegen::AstEmitter::NODE_EMITTERS.key?(node_class), name
    end
  end

  def test_regexp_has_no_legacy_matcher_state
    source = File.read(File.join(PROJECT_ROOT, "lib", "onibi.rb"))

    refute_includes source, "@bytecode"
    refute_includes source, "dfa_specialization"
    refute_includes source, "RegexpMatching"
    refute_includes source, "codegen_default"
  end
end
