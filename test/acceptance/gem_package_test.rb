# frozen_string_literal: true

require 'test_helper'
require 'open3'
require 'tmpdir'

class GemPackageTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  GEMSPEC = File.join(ROOT, 'onibi.gemspec')

  def test_onibi_gemspec_describes_a_pure_ruby_gem
    specification = Gem::Specification.load(GEMSPEC)

    refute_nil specification
    assert_equal 'onibi', specification.name
    assert_equal 'Apache-2.0', specification.license
    assert_equal Gem::Requirement.new('>= 4.0.6'), specification.required_ruby_version
    assert_empty specification.runtime_dependencies
    assert_includes specification.files, 'lib/onibi.rb'
    assert_includes specification.files, 'lib/onibi/version.rb'
  end

  def test_built_gem_installs_and_loads_in_a_clean_gem_home
    Dir.mktmpdir('onibi-gem-acceptance') do |directory|
      gem_path = File.join(directory, 'onibi.gem')
      install_dir = File.join(directory, 'gems')

      build_output, build_status = Open3.capture2e(
        RbConfig.ruby,
        '-S',
        'gem',
        'build',
        GEMSPEC,
        '--output',
        gem_path,
        chdir: ROOT
      )

      assert build_status.success?, build_output
      assert_path_exists gem_path

      install_output, install_status = Open3.capture2e(
        RbConfig.ruby,
        '-S',
        'gem',
        'install',
        gem_path,
        '--local',
        '--no-document',
        '--install-dir',
        install_dir
      )

      assert install_status.success?, install_output

      lib_path = File.join(install_dir, 'gems', 'onibi-0.1.0', 'lib')
      output, status = Open3.capture2e(
        RbConfig.ruby,
        '-I',
        lib_path,
        '-e',
        'require "onibi"; abort unless Onibi::VERSION == "0.1.0"'
      )

      assert status.success?, output
    end
  end
end
