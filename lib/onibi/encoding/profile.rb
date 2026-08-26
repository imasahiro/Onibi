# frozen_string_literal: true

module Onibi
  # Encoding capabilities used by the compiler and the execution boundary.
  #
  # Ruby's Encoding object exposes the low-level properties of an encoding,
  # but it does not expose the policy that a regexp engine needs.  Keep that
  # policy in one small object.  The generated table contains one row for each
  # canonical encoding available to the MRI version used to build Onibi.
  module EncodingSupport
    Profile = Struct.new(
      :name,
      :family,
      :ascii_compatible,
      :dummy,
      :property_mode,
      :binary_escape_multibyte,
      keyword_init: true
    ) do
      def binary?
        family == :binary
      end

      def ascii?
        family == :ascii
      end

      def unicode?
        family == :unicode
      end

      def legacy_multibyte?
        family == :legacy_multibyte
      end

      def binary_escape_multibyte?
        binary_escape_multibyte
      end
    end

    # The generated companion file fills and freezes this registry during
    # require.  Keep the initial object private to the load sequence.
    PROFILE_BY_NAME = {}

    module_function

    def profile(encoding)
      name = encoding_name(encoding)
      PROFILE_BY_NAME.fetch(name) { fallback_profile(encoding) }
    end

    def encoding_name(encoding)
      return encoding.name if encoding.respond_to?(:name)

      Encoding.find(encoding).name
    end

    def binary?(encoding)
      return false unless encoding

      profile(encoding).binary?
    end

    def ascii?(encoding)
      return false unless encoding

      profile(encoding).ascii?
    end

    def unicode?(encoding)
      return false unless encoding

      profile(encoding).unicode?
    end

    def legacy_multibyte?(encoding)
      return false unless encoding

      profile(encoding).legacy_multibyte?
    end

    def ascii_compatible?(encoding)
      return false unless encoding

      profile(encoding).ascii_compatible
    end

    def non_ascii_compatible?(encoding)
      return false unless encoding

      !ascii_compatible?(encoding)
    end

    def property_mode(encoding)
      return :ascii unless encoding

      profile(encoding).property_mode
    end

    def binary_escape_multibyte?(encoding)
      return false unless encoding

      profile(encoding).binary_escape_multibyte?
    end

    def byte_mode?(encoding)
      binary?(encoding)
    end

    def utf8?(encoding)
      encoding_name(encoding) == "UTF-8"
    end

    def us_ascii?(encoding)
      encoding_name(encoding) == "US-ASCII"
    end

    def iso_8859_1?(encoding)
      encoding_name(encoding) == "ISO-8859-1"
    end

    def fallback_profile(encoding)
      ascii_compatible = encoding.respond_to?(:ascii_compatible?) && encoding.ascii_compatible?
      Profile.new(
        name: encoding_name(encoding),
        family: ascii_compatible ? :ascii_compatible : :non_ascii_compatible,
        ascii_compatible: ascii_compatible,
        dummy: encoding.respond_to?(:dummy?) && encoding.dummy?,
        property_mode: :ascii,
        binary_escape_multibyte: false
      ).freeze
    end
    private_class_method :fallback_profile
  end
end
