# frozen_string_literal: true

require "test_helper"
require "open3"
require "tmpdir"
require "rbconfig"
require "rubygems/package"

class PackageTest < Minitest::Test
  def test_gem_installs_in_a_clean_home_and_loads_public_api
    Dir.mktmpdir("onibi-package") do |directory|
      gem_path = build_package(directory)
      gem_home = install_package(directory, gem_path)

      assert_command_success(run_smoke(gem_home))
    end
  end

  def test_gem_contains_release_files_and_no_runtime_dependencies
    Dir.mktmpdir("onibi-package") do |directory|
      gem_path = build_package(directory)
      specification = Gem::Package.new(gem_path).spec

      assert_equal "0.1.0", specification.version.to_s
      assert_empty specification.runtime_dependencies
      assert_includes specification.files, "README.md"
      assert_includes specification.files, "LICENSE"
      assert_includes specification.files, "onibi.gemspec"
      assert_includes specification.files, "lib/onibi.rb"
    end
  end

  private

  def run_command(*command)
    Open3.capture3(*command, chdir: File.expand_path("../..", __dir__))
  end

  def build_package(directory)
    gem_path = File.join(directory, "onibi.gem")

    assert_command_success(run_command("gem", "build", "onibi.gemspec", "--output", gem_path))
    gem_path
  end

  def install_package(directory, gem_path)
    gem_home = File.join(directory, "gems")
    command = ["gem", "install", "--local", "--install-dir", gem_home, gem_path, "--no-document"]

    assert_command_success(run_command(*command))
    gem_home
  end

  def run_smoke(gem_home)
    environment = { "GEM_HOME" => gem_home, "GEM_PATH" => gem_home }
    command = [RbConfig.ruby, "-e", 'require "onibi"; abort unless Onibi::Regexp.new("a").match?("a")']

    run_command(environment, *command)
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
