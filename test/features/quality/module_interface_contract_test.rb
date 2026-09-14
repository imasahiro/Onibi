# frozen_string_literal: true

require_relative "../../test_helper"

class ModuleInterfaceContractTest < Minitest::Test
  ROOT = File.expand_path("../../../", __dir__)
  EXT = File.join(ROOT, "ext", "onibi")

  MODULE_HEADERS = {
    "ast.c" => ["onibi_ast_internal.h"],
    "compiler.c" => ["onibi_ast_internal.h", "onibi_compiler_internal.h",
                     "onibi_gir_internal.h"],
    "diagnostics.c" => ["onibi_ast_internal.h", "onibi_compiler_internal.h",
                        "onibi_exec_internal.h", "onibi_gir_internal.h",
                        "onibi_rseq_internal.h"],
    "exec_dynamic.c" => ["onibi_encoding_internal.h", "onibi_exec_internal.h",
                         "onibi_rseq_internal.h"],
    "gir.c" => ["onibi_ast_internal.h", "onibi_gir_internal.h"],
    "match.c" => ["onibi_encoding_internal.h", "onibi_exec_internal.h",
                  "onibi_ruby_api_internal.h"],
    "nfa.c" => ["onibi_ast_internal.h", "onibi_gir_internal.h"],
    "onibi_init.c" => ["onibi_ruby_api_internal.h"],
    "parser.c" => ["onibi_ast_internal.h"],
    "rseq.c" => ["onibi_ast_internal.h", "onibi_compiler_internal.h",
                 "onibi_gir_internal.h", "onibi_rseq_internal.h",
                 "onibi_ruby_api_internal.h"],
    "rseq_runtime.c" => ["onibi_encoding_internal.h", "onibi_exec_internal.h",
                         "onibi_rseq_internal.h"],
    "token.c" => ["onibi_ast_internal.h"],
    "unicode.c" => ["onibi_encoding_internal.h"]
  }.freeze

  def test_each_pipeline_module_declares_its_private_contracts
    MODULE_HEADERS.each do |source_name, headers|
      source = File.read(File.join(EXT, source_name))
      headers.each do |header|
        assert_includes source, %(#include "#{header}"),
                        "#{source_name} must include #{header}"
      end
    end
  end

  def test_private_headers_have_include_guards
    MODULE_HEADERS.values.flatten.uniq.each do |header_name|
      header = File.read(File.join(EXT, header_name))
      assert_match(/\A#ifndef ONIBI_.*_INTERNAL_H\n#define ONIBI_.*_INTERNAL_H/m,
                   header, header_name)
      assert_match(/#endif\s*\z/, header, header_name)
    end
  end

  def test_execution_context_and_raw_match_are_owned_by_execution_contract
    common = File.read(File.join(EXT, "onibi_common.c"))
    execution = File.read(File.join(EXT, "onibi_exec_internal.h"))

    refute_includes common, "} OnibiRawMatch;"
    refute_match(/typedef struct \{.*?\} OnibiExecCtx;/m, common)
    assert_includes execution, "typedef struct OnibiRawMatch"
    assert_includes execution, "typedef struct OnibiExecCtx"
    assert_includes execution, "static OnibiExecStatus onibi_execute"
  end

  def test_common_uses_named_contract_types
    common = File.read(File.join(EXT, "onibi_common.c"))

    assert_includes common, "#include \"onibi_ast_internal.h\""
    assert_includes common, "#include \"onibi_compiler_internal.h\""
    assert_includes common, "#include \"onibi_encoding_internal.h\""
    assert_includes common, "#include \"onibi_exec_internal.h\""
    assert_includes common, "struct onibi_regexp_t"
    refute_includes common, "typedef enum {\n    ONIBI_COMPILE_OK"
  end
end
