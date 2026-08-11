# frozen_string_literal: true

require "yaml"

module TestFixtures
  NAMES = {
    syntax: %w[syntax core.yml],
    encoding: %w[encoding matrix.yml],
    api_inventory: %w[api inventory.yml],
    api_differential: %w[api differential.yml]
  }.freeze

  module_function

  def load(name)
    YAML.safe_load(File.read(File.join(FIXTURES_ROOT, *NAMES.fetch(name))), aliases: true)
  end
end
