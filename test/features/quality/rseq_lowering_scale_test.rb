# frozen_string_literal: true

require "test_helper"

class RseqLoweringScaleTest < Minitest::Test
  def diagnostics(pattern)
    Onibi::Regexp.new(pattern).send(:__onibi_diagnostics__, "")
  end

  def test_class_hashing_has_bounded_probes_and_first_insertion_indexes
    count = 26
    pattern = (0...count).map { |index| "[a-#{(97 + index).chr}]" }.join
    info = diagnostics(pattern)

    assert_equal (0...count).to_a, info[:state_payloads].first(count)
    assert_equal count, info[:class_kinds].length
    assert_operator info[:lowering_work][:gir_class_probes], :<, count * 4
    assert_operator info[:lowering_work][:rseq_class_probes], :<, count * 4
  end

  def test_physical_class_key_omits_nonserialized_casefold_metadata
    info = diagnostics("[!](?i:[!])")

    assert_equal 1, info[:class_kinds].length
    assert_equal [0, 0], info[:state_payloads].first(2)
    assert_equal 1, info[:lowering_work][:rseq_class_probes]
  end

  def test_literal_hashing_keeps_first_insertion_indexes
    characters = ("A".."Z").to_a + ("a".."z").to_a + ("0".."9").to_a
    info = diagnostics(characters.join)

    assert_equal (0...characters.length).to_a,
                 info[:state_payloads].first(characters.length)
    assert_operator info[:lowering_work][:literal_probes], :<,
                    characters.length * 4
  end

  def test_prefix_walk_uses_one_grouped_edge_per_prefix_byte
    info = diagnostics("a" * 128)

    assert_equal 31, info[:lowering_work][:prefix_edges]
  end

  def test_large_repeated_action_programs_serialize_once
    count = 128
    info = diagnostics(Array.new(count, "\\ba").join("|"))
    action_offsets = info[:edges].filter_map { |(_, offset)| offset unless offset.zero? }

    assert_equal 2, info[:actions].length
    assert_equal [8], action_offsets.uniq
    assert_equal count, action_offsets.length
    assert_operator info[:lowering_work][:action_probes], :<, count * 4
  end
end
