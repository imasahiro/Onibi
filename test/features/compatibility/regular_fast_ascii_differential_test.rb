# frozen_string_literal: true

require "test_helper"

class RegularFastAsciiDifferentialTest < Minitest::Test
  def test_any_matches_mri_for_all_ascii_bytes
    onibi = Onibi::Regexp.new(".")
    mri = Regexp.new(".")
    0.upto(127) do |byte|
      subject = byte.chr(Encoding::ASCII_8BIT)
      info = onibi.send(:__onibi_diagnostics__, subject)
      expected = mri.match?(subject)
      assert_equal expected, info[:status] == 1, byte
      assert_equal 0, info[:dfs], byte
    end
  end

  def test_class_and_negated_class_match_mri_for_all_ascii_bytes
    [["[a-z]", "[a-z]"], ["[^a]", "[^a]"]].each do |pattern, oracle_pattern|
      onibi = Onibi::Regexp.new(pattern)
      mri = Regexp.new(oracle_pattern)
      0.upto(127) do |byte|
        subject = byte.chr(Encoding::ASCII_8BIT)
        info = onibi.send(:__onibi_diagnostics__, subject)
        assert_equal mri.match?(subject), info[:status] == 1, [pattern, byte]
        assert_equal 0, info[:dfs], [pattern, byte]
      end
    end
  end
end
