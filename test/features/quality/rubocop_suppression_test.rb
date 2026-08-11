# frozen_string_literal: true

require "test_helper"

class RuboCopSuppressionTest < Minitest::Test
  LIBRARY_PATH = File.join(PROJECT_ROOT, "lib")

  def test_library_code_contains_no_rubocop_suppression_directives
    library_files = Dir[File.join(LIBRARY_PATH, "**", "*.rb")]
    directives = library_files.flat_map do |file|
      File.readlines(file).select { |line| line.include?("rubocop:disable") || line.include?("rubocop:enable") }
    end

    assert_empty directives
  end
end
