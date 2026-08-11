# frozen_string_literal: true

require "test_helper"

class RubyCodegenDesignTest < Minitest::Test
  DESIGN_PATH = File.join(PROJECT_ROOT, "docs", "regexp-ruby-codegen-design.md")
  TASKS_PATH = File.join(PROJECT_ROOT, "docs", "regexp-ruby-codegen-task-list.md")
  CANONICAL_DESIGN_PATH = File.join(PROJECT_ROOT, "docs", "onibi-design.md")

  DESIGN_REQUIREMENTS = [
    "Regexp source -> Token stream -> AST -> generated Ruby matcher",
    "single generated-matcher architecture",
    "Semantic contract",
    "Backtracking and capture state",
    "Encoding and cursor model",
    "Compilation safety",
    "Resource limits",
    "Concurrency and Ractor",
    "Adversarial review disposition",
    "Migration and deletion criteria",
    "Rejected alternatives"
  ].freeze

  TASK_REQUIREMENTS = [
    "CODEGEN-001",
    "Dependency graph",
    "Definition of done",
    "failing acceptance test",
    "Remove the legacy VM, NFA, and DFA paths"
  ].freeze

  def test_codegen_design_records_the_architecture_and_operational_contracts
    design = File.read(DESIGN_PATH)

    DESIGN_REQUIREMENTS.each { |requirement| assert_includes design, requirement }
  end

  def test_codegen_task_list_is_ordered_and_has_completion_gates
    tasks = File.read(TASKS_PATH)

    TASK_REQUIREMENTS.each { |requirement| assert_includes tasks, requirement }
    expected_ids = (1..25).map { |number| format("CODEGEN-%03d", number) }
    assert_equal expected_ids, tasks.scan(/^### (CODEGEN-\d{3})/).flatten
  end

  def test_canonical_design_selects_ruby_codegen_instead_of_automata_execution
    design = File.read(CANONICAL_DESIGN_PATH)

    assert_includes design, "AST-to-Ruby code generation"
    refute_includes design, "Use a single bytecode VM with Thompson-NFA execution and runtime DFA specialization."
  end
end
