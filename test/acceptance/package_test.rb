# frozen_string_literal: true

require "test_helper"
require "open3"
require "tmpdir"
require "rbconfig"

class PackageTest < Minitest::Test
  def test_gem_installs_in_a_clean_home_and_loads_public_api
    Dir.mktmpdir("onibi-package") do |directory|
      gem_path = File.join(directory, "onibi.gem")
      gem_home = File.join(directory, "gems")

      build = run_command("gem", "build", "onibi.gemspec", "--output", gem_path)
      assert_command_success(build)

      install = run_command("gem", "install", "--local", "--install-dir", gem_home, gem_path, "--no-document")
      assert_command_success(install)

      smoke = run_command(
        { "GEM_HOME" => gem_home, "GEM_PATH" => gem_home },
        RbConfig.ruby,
        "-e",
        'require "onibi"; abort unless Onibi::Regexp.new("a").match?("a")'
      )
      assert_command_success(smoke)
    end
  end

  private

  def run_command(*command)
    Open3.capture3(*command, chdir: File.expand_path("../..", __dir__))
  end

  def build_output(result)
    _output, error, status = result
    "#{error}\n#{status}"
  end

  def assert_command_success(result)
    _output, _error, status = result

    assert status.success?, build_output(result)
  end
end
