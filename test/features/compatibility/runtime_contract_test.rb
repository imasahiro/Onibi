# frozen_string_literal: true

require "test_helper"
require "yaml"

class RuntimeContractTest < Minitest::Test
  RUNTIMES_PATH = File.join(PROJECT_ROOT, "docs", "v1-runtimes.yml")
  REQUIRED_RUNTIMES = %w[mri jruby truffleruby mruby].freeze

  def test_v1_runtime_matrix_pins_every_target
    runtimes = YAML.safe_load(File.read(RUNTIMES_PATH)).fetch("runtimes")

    assert_equal REQUIRED_RUNTIMES.sort, runtimes.map { |runtime| runtime.fetch("name") }.sort
    runtimes.each do |runtime|
      refute_empty runtime.fetch("version")
      refute_empty runtime.fetch("command")
    end
  end
end
