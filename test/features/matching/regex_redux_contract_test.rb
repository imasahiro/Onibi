# frozen_string_literal: true

require "stringio"
require "test_helper"
require_relative "../../../benchmark/regex_redux"

class RegexReduxContractTest < Minitest::Test
  def test_onibi_matches_mri_for_the_full_regex_redux_pipeline
    input = File.read(File.expand_path("../../../benchmark/fasta-500.txt", __dir__))

    assert_equal RegexRedux.new(StringIO.new(input), engine: :ruby).to_s,
                 RegexRedux.new(StringIO.new(input), engine: :onibi).to_s
  end
end
