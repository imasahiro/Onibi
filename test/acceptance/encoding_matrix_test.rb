# frozen_string_literal: true

require "test_helper"
require "yaml"

class EncodingMatrixTest < Minitest::Test
  MATRIX_PATH = File.expand_path("../../fixtures/regexp_encoding_matrix.yml", __dir__)
  REQUIRED_ENCODINGS = %w[ASCII-8BIT EUC-JP UTF-8 Windows-31J].freeze

  def test_encoding_matrix_covers_the_supported_baseline
    matrix = YAML.safe_load(File.read(MATRIX_PATH))

    assert_equal REQUIRED_ENCODINGS.sort, matrix.fetch("encodings").sort
    assert_equal REQUIRED_ENCODINGS.length**2, ascii_pair_cases(matrix).length
    matrix.fetch("cases").each { |fixture| assert_case_shape(fixture) }
  end

  def test_encoding_matrix_matches_mri
    matrix = YAML.safe_load(File.read(MATRIX_PATH))

    matrix.fetch("cases").each do |fixture|
      pattern = fixture.fetch("pattern").encode(fixture.fetch("pattern_encoding"))
      input = fixture.fetch("input").encode(fixture.fetch("input_encoding"))

      assert_equal expected_outcome(Regexp, pattern, input, fixture.fetch("options")),
                   expected_outcome(Onibi::Regexp, pattern, input, fixture.fetch("options")),
                   fixture.fetch("name")
    end
  end

  private

  def ascii_pair_cases(matrix)
    matrix.fetch("cases").select do |fixture|
      fixture.fetch("pattern") == "a" && fixture.fetch("input") == "a"
    end
  end

  def assert_case_shape(fixture)
    assert_equal %w[input input_encoding name options outcome pattern pattern_encoding].sort, fixture.keys.sort
    assert_kind_of String, fixture.fetch("input")
    assert_kind_of Array, fixture.fetch("options")
    assert_kind_of String, fixture.fetch("pattern")
    assert_includes REQUIRED_ENCODINGS, fixture.fetch("input_encoding")
    assert_includes REQUIRED_ENCODINGS, fixture.fetch("pattern_encoding")
    assert_includes %w[match no_match error], fixture.fetch("outcome")
  end

  def expected_outcome(regexp_class, pattern, input, options)
    constructor_options = regexp_class == Regexp ? 0 : options
    result = regexp_class.new(pattern, constructor_options).match?(input)
    result ? :match : :no_match
  rescue StandardError
    :error
  end
end
