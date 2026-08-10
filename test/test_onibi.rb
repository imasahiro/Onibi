# frozen_string_literal: true

require "test_helper"

class TestOnibi < Minitest::Test
  def test_that_it_has_a_version_number
    refute_nil ::Onibi::VERSION
  end

  def test_it_exposes_a_public_error_class
    assert_operator Onibi::Error, :<, StandardError
  end

  def test_gemspec_has_valid_metadata
    specification = Gem::Specification.load(File.expand_path("../onibi.gemspec", __dir__))

    refute_nil specification
    assert_silent { specification.validate }
  end
end
