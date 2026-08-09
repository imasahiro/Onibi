# frozen_string_literal: true

lib = File.expand_path('lib', __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'onibi/version'

Gem::Specification.new do |spec|
  spec.name          = 'onibi'
  spec.version       = Onibi::VERSION
  spec.authors       = ['Masahiro Ide']
  spec.email         = ['imasahiro9@gmail.com']
  spec.summary       = 'A pure Ruby regular expression engine'
  spec.description   = 'A pure Ruby regular expression engine with a Ruby-compatible API.'
  spec.homepage      = 'https://github.com/imasahiro/onibi'
  spec.license       = 'Apache-2.0'

  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = spec.homepage
  spec.metadata['changelog_uri'] = "#{spec.homepage}/blob/main/CHANGELOG.md"

  spec.required_ruby_version = '>= 4.0.6'
  spec.files = Dir.chdir(__dir__) do
    Dir.glob('**/*', File::FNM_DOTMATCH).select { |file| File.file?(file) }.reject do |file|
      file.match?(%r{\A(?:\.git|test|spec|features)/}) || file.end_with?('.gem')
    end
  end
  spec.bindir = 'bin'
  spec.executables = spec.files.grep(%r{\Abin/}) { |file| File.basename(file) }
  spec.require_paths = ['lib']

  spec.add_development_dependency 'bundler', '>= 1.17'
  spec.add_development_dependency 'minitest', '>= 5.0'
  spec.add_development_dependency 'rake', '>= 12.0'
  spec.add_development_dependency 'rubocop', '>= 1.0'
end
