# frozen_string_literal: true

require "minitest/autorun"

class PreCommitHookShellTest < Minitest::Test
  HOOK_PATH = File.expand_path("../../../.githooks/pre-commit", __dir__)

  def test_hook_uses_shell_features_supported_by_macos_bash
    hook = File.read(HOOK_PATH)

    refute_match(/\bmapfile\b|\breadarray\b/, hook)
  end
end
