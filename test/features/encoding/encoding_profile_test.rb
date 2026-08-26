# frozen_string_literal: true

require "test_helper"

class EncodingProfileTest < Minitest::Test
  def test_generated_profiles_cover_the_runtime_encoding_registry
    Encoding.list.each do |encoding|
      profile = Onibi::EncodingSupport.profile(encoding)

      assert_equal encoding.name, profile.name
      assert_equal encoding.ascii_compatible?, profile.ascii_compatible
      assert_equal encoding.dummy?, profile.dummy
      assert_same profile, Onibi::EncodingSupport.profile(encoding.name)
    end
  end

  def test_profiles_are_immutable
    assert Onibi::EncodingSupport::PROFILE_BY_NAME.frozen?
    assert Onibi::EncodingSupport::PROFILE_BY_NAME.values.all?(&:frozen?)
  end

  def test_profiles_describe_the_execution_families
    assert Onibi::EncodingSupport.binary?(Encoding::ASCII_8BIT)
    assert Onibi::EncodingSupport.ascii?(Encoding::US_ASCII)
    assert Onibi::EncodingSupport.unicode?(Encoding::UTF_8)
    assert Onibi::EncodingSupport.unicode?(Encoding::UTF_16LE)
    assert Onibi::EncodingSupport.legacy_multibyte?(Encoding::EUC_JP)
    assert Onibi::EncodingSupport.legacy_multibyte?(Encoding::Windows_31J)
  end

  def test_profiles_describe_binary_escape_validation
    %w[UTF-8 EUC-JP Windows-31J].each do |name|
      assert Onibi::EncodingSupport.binary_escape_multibyte?(Encoding.find(name))
    end

    refute Onibi::EncodingSupport.binary_escape_multibyte?(Encoding::ISO_8859_1)
  end

  def test_profile_helpers_are_based_on_canonical_encoding_names
    assert Onibi::EncodingSupport.utf8?(Encoding::UTF_8)
    assert Onibi::EncodingSupport.us_ascii?(Encoding::US_ASCII)
    assert Onibi::EncodingSupport.iso_8859_1?(Encoding::ISO_8859_1)
    refute Onibi::EncodingSupport.utf8?(Encoding::UTF_16LE)
  end

  def test_non_ascii_compatible_is_the_complement_of_ascii_compatible
    Encoding.list.each do |encoding|
      assert_equal !encoding.ascii_compatible?, Onibi::EncodingSupport.non_ascii_compatible?(encoding)
    end
  end
end
