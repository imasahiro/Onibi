# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "open3"
require "tmpdir"

class PreCommitHookTest < Minitest::Test
  def test_hook_rejects_a_commit_when_formatting_changes_staged_ruby
    Dir.mktmpdir("onibi-hook") do |directory|
      setup_repository(directory)
      write_bad_ruby_file(directory)

      output, _error, status = run_git(directory, "commit", "-m", "format")

      refute status.success?, output
      refute_equal "def example;end\n", File.read(File.join(directory, "example.rb"))
    end
  end

  private

  def setup_repository(directory)
    FileUtils.mkdir_p(File.join(directory, ".githooks"))
    FileUtils.cp(hook_path, File.join(directory, ".githooks", "pre-commit"))
    FileUtils.cp(rubocop_config_path, File.join(directory, ".rubocop.yml"))
    run_git(directory, "init", "-q")
    run_git(directory, "config", "user.email", "test@example.com")
    run_git(directory, "config", "user.name", "Test")
    run_git(directory, "config", "core.hooksPath", ".githooks")
  end

  def write_bad_ruby_file(directory)
    File.write(File.join(directory, "example.rb"), "def example;end\n")
    run_git(directory, "add", "example.rb")
  end

  def run_git(directory, *arguments)
    Open3.capture3("git", *arguments, chdir: directory)
  end

  def hook_path
    File.expand_path("../../.githooks/pre-commit", __dir__)
  end

  def rubocop_config_path
    File.expand_path("../../.rubocop.yml", __dir__)
  end
end
