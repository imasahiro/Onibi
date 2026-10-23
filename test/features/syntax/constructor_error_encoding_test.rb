# frozen_string_literal: true

require "test_helper"

class ConstructorErrorEncodingTest < Minitest::Test
  CASES = [
    {
      id: "empty_angle_name",
      bytes: [40, 63, 60, 62, 97, 41],
      encoding: "UTF-8",
      valid_encoding: true,
      mri_message_encoding: "UTF-8"
    },
    {
      id: "empty_quote_name",
      bytes: [40, 63, 39, 39, 97, 41],
      encoding: "UTF-8",
      valid_encoding: true,
      mri_message_encoding: "UTF-8"
    },
    {
      id: "leading_ascii_digit_angle",
      bytes: [40, 63, 60, 49, 119, 111, 114, 100, 62, 97, 41],
      encoding: "UTF-8",
      valid_encoding: true,
      mri_message_encoding: "UTF-8"
    },
    {
      id: "leading_ascii_digit_quote",
      bytes: [40, 63, 39, 49, 119, 111, 114, 100, 39, 97, 41],
      encoding: "UTF-8",
      valid_encoding: true,
      mri_message_encoding: "UTF-8"
    },
    {
      id: "leading_hyphen_angle",
      bytes: [40, 63, 60, 45, 119, 111, 114, 100, 62, 97, 41],
      encoding: "UTF-8",
      valid_encoding: true,
      mri_message_encoding: "UTF-8"
    },
    {
      id: "leading_hyphen_quote",
      bytes: [40, 63, 39, 45, 119, 111, 114, 100, 39, 97, 41],
      encoding: "UTF-8",
      valid_encoding: true,
      mri_message_encoding: "UTF-8"
    },
    {
      id: "leading_unicode_digit_angle",
      bytes: [40, 63, 60, 239, 188, 145, 119, 111, 114, 100, 62, 97, 41],
      encoding: "UTF-8",
      valid_encoding: true,
      mri_message_encoding: "UTF-8"
    },
    {
      id: "leading_unicode_digit_quote",
      bytes: [40, 63, 39, 239, 188, 145, 119, 111, 114, 100, 39, 97, 41],
      encoding: "UTF-8",
      valid_encoding: true,
      mri_message_encoding: "UTF-8"
    },
    {
      id: "invalid_utf8_angle",
      bytes: [40, 63, 60, 255, 62, 97, 41],
      encoding: "UTF-8",
      valid_encoding: false,
      mri_message_encoding: "UTF-8"
    },
    {
      id: "invalid_utf8_quote",
      bytes: [40, 63, 39, 255, 39, 97, 41],
      encoding: "UTF-8",
      valid_encoding: false,
      mri_message_encoding: "UTF-8"
    },
    {
      id: "invalid_windows31j_angle",
      bytes: [40, 63, 60, 129, 62, 97, 41],
      encoding: "Windows-31J",
      valid_encoding: false,
      mri_message_encoding: "Windows-31J"
    },
    {
      id: "invalid_windows31j_quote",
      bytes: [40, 63, 39, 129, 39, 97, 41],
      encoding: "Windows-31J",
      valid_encoding: false,
      mri_message_encoding: "Windows-31J"
    },
    {
      id: "invalid_hex_capture_name",
      bytes: [40, 63, 60, 97, 92, 120, 62, 97, 41],
      encoding: "UTF-8",
      valid_encoding: true,
      mri_message_encoding: "UTF-8"
    },
    {
      id: "invalid_control_unicode_capture_name",
      bytes: [40, 63, 60, 97, 92, 99, 92, 117, 48, 48, 52, 49, 62, 97, 41],
      encoding: "UTF-8",
      valid_encoding: true,
      mri_message_encoding: "UTF-8"
    },
    {
      id: "invalid_nested_control_capture_name",
      bytes: [40, 63, 60, 97, 92, 99, 92, 99, 65, 62, 97, 41],
      encoding: "UTF-8",
      valid_encoding: true,
      mri_message_encoding: "UTF-8"
    }
  ].freeze

  CASES.each do |case_data|
    define_method("test_#{case_data.fetch(:id)}_preserves_mri_error_encoding") do
      encoding = Encoding.find(case_data.fetch(:encoding))
      pattern = case_data.fetch(:bytes).pack("C*").force_encoding(encoding)
      label = case_data.fetch(:id)

      assert_equal case_data.fetch(:bytes), pattern.bytes, label
      assert_equal case_data.fetch(:valid_encoding), pattern.valid_encoding?, label
      assert_equal case_data.fetch(:encoding), pattern.encoding.name, label

      mri_error = assert_raises(::RegexpError, label) do
        ::Regexp.new(pattern)
      end
      onibi_error = assert_raises(Onibi::RegexpError, label) do
        Onibi::Regexp.new(pattern)
      end

      assert_instance_of ::RegexpError, mri_error, label
      assert_instance_of Onibi::RegexpError, onibi_error, label
      assert_kind_of ::RegexpError, onibi_error, label
      assert_equal case_data.fetch(:mri_message_encoding),
                   mri_error.message.encoding.name, label
      assert_equal mri_error.message.bytes, onibi_error.message.bytes, label
      assert_equal mri_error.message.encoding,
                   onibi_error.message.encoding, label
    end
  end
end
