# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = "onibi"
  spec.version = "0.1.0"
  spec.authors = ["Masahiro Ide"]
  spec.email = ["imasahiro9@gmail.com"]

  spec.summary = "An MRI-focused regular expression engine"
  spec.description = "An MRI-focused regular expression engine with an Onibi::Regexp API."
  spec.homepage = "https://github.com/imasahiro/Onibi"
  spec.required_ruby_version = ">= 4.0.6"
  spec.license = "Apache-2.0"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "#{spec.homepage}/tree/main"

  # Uncomment the line below to require MFA for gem pushes.
  # This helps protect your gem from supply chain attacks by ensuring
  # no one can publish a new version without multi-factor authentication.
  # See: https://guides.rubygems.org/mfa-requirement-opt-in/
  # spec.metadata["rubygems_mfa_required"] = "true"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    files = ls.readlines("\x0", chomp: true)
    files.select! { |file| File.file?(File.join(__dir__, file)) }
    files.reject do |f|
      f.start_with?(*%w[bin/ Gemfile .gitignore test/ .github/ .rubocop.yml])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  # Uncomment to register a new dependency of your gem
  # spec.add_dependency "example-gem", "~> 1.0"

  # For more information and examples about making a new gem, check out our
  # guide at: https://guides.rubygems.org/make-your-own-gem/
end
