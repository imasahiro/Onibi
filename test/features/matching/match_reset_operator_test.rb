# frozen_string_literal: true

require "English"
require "test_helper"

class MatchResetOperatorTest < Minitest::Test
  EXECUTOR_IDS = { regular: 0, tagged: 1, dynamic: 2 }.freeze

  CASES = [
    [:historical_basic, [97, 92, 75, 98], [227, 129, 130, 97, 98], :tagged],
    [:capture_around_reset,
     [40, 63, 60, 112, 114, 101, 102, 105, 120, 62, 97, 41, 92, 75,
      40, 63, 60, 116, 97, 105, 108, 62, 98, 41],
     [227, 129, 130, 97, 98], :tagged],
    [:empty_after_reset, [97, 92, 75, 40, 63, 61, 98, 41],
     [227, 129, 130, 97, 98], :tagged],
    [:first_alternative_success, [97, 92, 75, 98, 124, 97, 92, 75, 99],
     [227, 129, 130, 97, 98], :tagged],
    [:failed_then_successful_alternative,
     [46, 92, 75, 120, 124, 46, 46, 92, 75, 98],
     [227, 129, 130, 97, 98], :tagged],
    [:all_alternatives_fail,
     [46, 92, 75, 120, 124, 46, 46, 92, 75, 99],
     [227, 129, 130, 97, 98], :tagged],
    [:failed_reset_then_success_without_reset, [46, 92, 75, 120, 124, 98],
     [227, 129, 130, 97, 98], :tagged],
    [:no_reset_regular, [98], [227, 129, 130, 97, 98], :regular],
    [:no_reset_tagged, [92, 66, 120], [195, 169, 120], :tagged],
    [:no_reset_dynamic, [40, 97, 41, 92, 49], [227, 129, 130, 97, 97], :dynamic]
  ].freeze

  def test_match_data_and_operators_match_mri_on_native_paths
    prior_line = $LAST_READ_LINE
    observations = CASES.map do |name, pattern_bytes, subject_bytes, executor|
      pattern = utf8(pattern_bytes)
      subject = utf8(subject_bytes)
      mri_regexp = ::Regexp.new(pattern, 0)
      onibi_regexp = Onibi::Regexp.new(pattern, 0)
      expected_match = mri_regexp.match(subject)
      expected_eq_match = mri_regexp =~ subject
      $_ = subject
      expected_tilde = ~mri_regexp
      diagnostics = onibi_regexp.send(:__onibi_diagnostics__, subject)

      assert_native_route(name, executor, expected_match, diagnostics)
      [name, subject, onibi_regexp, expected_match, expected_eq_match, expected_tilde]
    end

    failures = []
    without_mri_regexp_calls do
      observations.each do |name, subject, regexp, expected_match, expected_eq, expected_tilde|
        actual_match = regexp.match(subject)
        expected_signature = match_signature(expected_match)
        actual_signature = match_signature(actual_match)
        record_difference(failures, name, "MatchData", expected_signature, actual_signature)
        actual_eq = regexp =~ subject
        record_difference(failures, name, "=~", expected_eq, actual_eq)

        $_ = subject
        actual_tilde = ~regexp
        record_difference(failures, name, "~", expected_tilde, actual_tilde)
        failures << "#{name} changed $_" unless subject == $LAST_READ_LINE
      end
    end
    assert_empty failures, failures.join("\n")
  ensure
    $LAST_READ_LINE = prior_line
  end

  private

  def utf8(bytes)
    bytes.pack("C*").force_encoding(Encoding::UTF_8)
  end

  def match_signature(match)
    return nil unless match

    {
      values: match.to_a,
      names: match.names,
      named_captures: match.named_captures,
      offsets: (0...match.length).map { |index| match.offset(index) },
      raw_ranges: (0...match.length).map do |index|
        [match.bytebegin(index), match.byteend(index)]
      end
    }
  end

  def assert_native_route(name, executor, expected_match, info)
    assert info[:rseq], name
    assert_equal EXECUTOR_IDS.fetch(executor), info[:exec_kind], name
    assert_operator info.fetch(executor), :>, 0, name
    assert_equal 0, info[:fallback], name
    assert_equal :none, info[:fallback_reason], name
    assert_equal :none, info[:executor_error_kind], name
    assert_equal expected_match ? 1 : 0, info[:status], name
    assert_equal 0, info[:dfs], name
  end

  def record_difference(failures, name, operation, expected, actual)
    return if expected == actual

    failures << [
      "#{name} #{operation}",
      "expected #{expected.inspect}",
      "got #{actual.inspect}"
    ].join(": ")
  end

  def without_mri_regexp_calls
    names = %i[match =~]
    originals = names.to_h { |name| [name, ::Regexp.instance_method(name)] }
    names.each do |name|
      ::Regexp.define_method(name) { |*| raise "MRI Regexp##{name} called" }
    end
    yield
  ensure
    originals&.each { |name, method| ::Regexp.define_method(name, method) }
  end
end
