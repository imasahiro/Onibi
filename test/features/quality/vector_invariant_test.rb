# frozen_string_literal: true

require "test_helper"

class VectorInvariantTest < Minitest::Test
  def setup
    @regexp = Onibi::Regexp.new("a")
  end

  def test_self_append_survives_reallocation
    assert_equal [1, 2, 3, 1, 2, 3], vector_diagnostic(:vector_self_append)
  end

  def test_source_slice_append_survives_reallocation
    assert_equal [1, 2, 3, 2, 3], vector_diagnostic(:vector_slice_append)
  end

  def test_insert_rejects_index_above_count
    error = assert_raises(ArgumentError) do
      vector_diagnostic(:vector_invalid_insert)
    end

    assert_equal "vector insert index is out of range", error.message
  end

  def test_owned_self_append_survives_reallocation
    assert_equal [1, 2, 3, 1, 2, 3],
                 vector_diagnostic(:owned_vector_self_append)
  end

  def test_owned_source_slice_append_survives_reallocation
    assert_equal [1, 2, 3, 2, 3],
                 vector_diagnostic(:owned_vector_slice_append)
  end

  def test_owned_insert_rejects_index_above_count
    error = assert_raises(ArgumentError) do
      vector_diagnostic(:owned_vector_invalid_insert)
    end

    assert_equal "vector insert index is out of range", error.message
  end

  private

  def vector_diagnostic(scenario)
    @regexp.send(:__onibi_gir_verifier_diagnostics__, scenario)
  end
end
