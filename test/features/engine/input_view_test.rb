# frozen_string_literal: true

require_relative "../../test_helper"

class InputViewTest < Minitest::Test
  def test_utf8_character_and_byte_boundaries
    view = Onibi::InputView.new("aあb")

    assert_equal 3, view.character_length
    assert_equal [0, 1, 4, 5], ((0..3).map { |index| view.byte_offset(index) })
    assert_equal 2, view.character_index(4)
    assert_equal "あ", view.slice(1, 1)
  end

  def test_binary_and_empty_inputs_do_not_mutate_string
    input = "\xFF\x00".b
    view = Onibi::InputView.new(input)

    assert_equal 2, view.character_length
    assert_equal [0, 1, 2], ((0..2).map { |index| view.byte_offset(index) })
    assert_equal "", Onibi::InputView.new("").slice(0, 0)
    assert_equal "\xFF\x00".b, view.slice(0)
    assert_equal "\xFF\x00".b, input
  end

  def test_non_boundary_byte_offsets_are_rejected
    error = assert_raises(IndexError) { Onibi::InputView.new("あ").character_index(1) }

    assert_match(/character boundary/, error.message)
  end
end
