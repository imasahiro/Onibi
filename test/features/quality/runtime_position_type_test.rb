# frozen_string_literal: true

require "test_helper"

class RuntimePositionTypeTest < Minitest::Test
  EXTENSION_ROOT = File.expand_path("../../../ext/onibi", __dir__)

  def test_position_and_repeat_aliases_keep_their_contracts
    common = source("onibi_common.c")
    execution = source("onibi_exec_internal.h")
    ir = source("onibi_ir.h")

    assert_includes execution, "typedef OnigPosition OnibiBytePos;"
    assert_includes execution, "typedef OnigPosition OnibiRegisterValue;"
    assert_includes ir, "typedef long OnibiRepeatCount;"
    assert_includes common, "sizeof(OnibiBytePos) == sizeof(OnigPosition)"
    assert_includes common, "sizeof(OnibiRegisterValue) == sizeof(OnigPosition)"
    assert_includes common, "sizeof(OnibiRepeatCount) == sizeof(long)"
    assert_includes ir, "OnibiRepeatCount *values;"
  end

  def test_execution_context_uses_byte_positions
    context = declaration(source("onibi_exec_internal.h"), "OnibiExecCtx")

    refute_nil context
    %w[search_origin attempt_start reported_start current_position].each do |field|
      assert_includes context, "OnibiBytePos #{field};"
    end
    assert_includes context, "OnibiBytePos matched_end;"
    assert_includes context, "OnibiRawMatch *raw_match;"
    refute_match(/\blong\b/, context)
  end

  def test_simple_frame_uses_typed_position_counter_and_capture_storage
    frame = declaration(source("rseq_runtime.c"), "onibi_simple_frame_t")

    refute_nil frame
    assert_includes frame, "OnibiBytePos pos;"
    assert_includes frame, "OnibiRepeatCount *counters;"
    assert_includes frame, "OnibiBytePos *captures;"
    refute_match(/\blong\b/, frame)
  end

  def test_vm_search_apis_use_typed_byte_ranges
    common = source("onibi_common.c")
    match = source("match.c")
    declaration_text = common[/static OnibiExecStatus\s+onibi_vm_search\(.*?;/m]
    body = match[/static OnibiExecStatus\s+onibi_vm_search\(.*?\n}\n/m]
    ensure_state = declaration(match, "OnibiSearchEnsure")

    [declaration_text, body].each do |api|
      refute_nil api
      assert_match(/OnibiBytePos\s+search_origin/, api)
      assert_match(/OnibiRawMatch\s+\*raw_match/, api)
      refute_match(/match_(?:start|end)/, api)
      refute_match(/\blong\b/, api)
    end

    refute_nil ensure_state
    assert_includes ensure_state, "OnibiBytePos origin;"
    assert_includes ensure_state, "OnibiRawMatch *raw_match;"
    refute_match(/\blong\b/, ensure_state)
  end

  def test_capture_arrays_use_byte_positions
    common = source("onibi_common.c")
    execution = source("onibi_exec_internal.h")
    dynamic = source("exec_dynamic.c")
    diagnostics = source("diagnostics.c")
    runtime = source("rseq_runtime.c")
    match = source("match.c")
    captures = [common, execution, dynamic, diagnostics, runtime, match].join("\n")

    raw_match = execution[/typedef struct OnibiRawMatch \{.*?\} OnibiRawMatch;/m]

    refute_nil raw_match
    assert_includes raw_match, "OnibiBytePos begin_byte;"
    assert_includes raw_match, "OnibiBytePos end_byte;"
    assert_includes raw_match, "OnibiBytePos *beg;"
    assert_includes raw_match, "OnibiBytePos *end;"
    refute_match(/onibi_regular_capture_result/, common)
    assert_match(/OnibiBytePos\s*\*\s*captures/, captures)
    assert_match(/OnibiBytePos\s+capture_beg\[/, dynamic)
    assert_match(/OnibiBytePos\s*\*\s*beg/, diagnostics)
    assert_match(/OnibiBytePos\s*\*\s*end/, diagnostics)
    %w[captures capture_result match_start match_end beg].each do |name|
      refute_match(/\blong\s*\*+\s*#{name}\b/, captures)
      refute_match(/\blong\s+#{name}\b/, captures)
    end
  end

  def test_semantic_reads_use_position_and_counter_helpers
    dynamic = source("exec_dynamic.c")
    position = dynamic[/static OnibiBytePos\s+onibi_semantic_position_read\(.*?\n}\n/m]
    counter = dynamic[/static OnibiRepeatCount\s+onibi_semantic_counter_read\(.*?\n}\n/m]

    refute_nil position
    refute_nil counter
    assert_includes position, "OnibiBytePos default_value"
    assert_includes position, "OnibiRegisterValue"
    assert_includes counter, "OnibiRepeatCount default_value"
    assert_includes counter, "OnibiRegisterValue"
    refute_match(/\blong\b/, position)
    refute_match(/\blong\b/, counter)
    assert_match(/OnibiBytePos\s+begin\s*=\s*onibi_semantic_position_read/, dynamic)
    assert_match(/OnibiRepeatCount\s+current\s*=\s*onibi_semantic_counter_read/, dynamic)
    refute_match(/\b(?:long|OnigPosition)\b[^;\n]*onibi_semantic_register_read/, dynamic)
  end

  def test_byte_lengths_and_ruby_character_indexes_keep_long
    dynamic = source("exec_dynamic.c")
    rseq = source("rseq.c")
    unicode = source("unicode.c")

    assert_match(/long\s+\*width/, dynamic)
    assert_includes dynamic, "long step_width"
    assert_match(/long\s+character(?:_length)?/, rseq)
    assert_includes rseq, "long character;"
    assert_match(/static long\s+onibi_grapheme_width\(VALUE str, OnibiBytePos pos\)/,
                 unicode)
  end

  private

  def source(name)
    File.read(File.join(EXTENSION_ROOT, name))
  end

  def declaration(text, name)
    text[/typedef struct \{.*?\} #{Regexp.escape(name)};/m]
  end
end
