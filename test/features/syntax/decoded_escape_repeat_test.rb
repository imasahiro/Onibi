# frozen_string_literal: true

require "json"

module DecodedEscapeRepeatCases
  module_function

  def build
    cases = []
    add = lambda do |id, encoding, pattern_bytes, subject_bytes, options = 0|
      cases << {
        id: id,
        encoding: encoding,
        options: options,
        pattern_bytes: pattern_bytes.bytes,
        subject_bytes: subject_bytes
      }
    end

    ascii_subjects = {
      "?" => [[0x41], [0x41, 0x42]],
      "*" => [[0x41], [0x41, 0x42, 0x42]],
      "+" => [[0x41, 0x42, 0x42], [0x41, 0x42, 0x41, 0x42]],
      "{2}" => [[0x41, 0x42, 0x42], [0x41, 0x42, 0x41, 0x42]],
      "{2,3}" => [[0x41, 0x42, 0x42], [0x41, 0x42, 0x41, 0x42]]
    }

    %w[UTF-8 Windows-31J EUC-JP].each do |encoding|
      ascii_subjects.each do |quantifier, subjects|
        id_root = "ascii-#{encoding.downcase}-#{quantifier.delete("{} ,")}"
        if encoding == "UTF-8" && quantifier == "+"
          id_root = "c21a-exact"
          source = %q(\A\x41\x42 +\z).b
          options = 2
        else
          source = "\\A\\x41(\\x42#{quantifier})\\z".b
          options = 0
        end
        subjects.each_with_index do |subject, index|
          suffix = index.zero? ? "expected" : "contrasting"
          add.call("#{id_root}-#{suffix}", encoding, source, subject, options)
        end
      end
    end
    add.call("ascii-run-no-match", "UTF-8", %q(\A\x41\x42 +\z).b,
             [0x41, 0x58], 2)

    add.call("octal-run-abb", "UTF-8", %q(\A(\101\102+)\z).b,
             [0x41, 0x42, 0x42])
    add.call("octal-run-abab", "UTF-8", %q(\A(\101\102+)\z).b,
             [0x41, 0x42, 0x41, 0x42])
    add.call("octal-run-no-match", "UTF-8", %q(\A(\101\102+)\z).b,
             [0x41, 0x58])
    add.call("mixed-hex-width-expected", "UTF-8", %q(\A(\x4\x42+)\z).b,
             [0x04, 0x42, 0x42])
    add.call("mixed-hex-width-contrasting", "UTF-8", %q(\A(\x4\x42+)\z).b,
             [0x04, 0x42, 0x04, 0x42])
    add.call("mixed-hex-width-no-match", "UTF-8", %q(\A(\x4\x42+)\z).b,
             [0x04, 0x58])

    encoded_sets = {
      "UTF-8" => {
        a: [0xE3, 0x81, 0x82], b: [0xE3, 0x81, 0x84], c: [0xE3, 0x81, 0x86]
      },
      "Windows-31J" => {
        a: [0x82, 0xA0], b: [0x82, 0xA2], c: [0x82, 0xA4]
      },
      "EUC-JP" => {
        a: [0xA4, 0xA2], b: [0xA4, 0xA4], c: [0xA4, 0xA6]
      }
    }

    encoded_sets.each do |encoding, chars|
      a = chars.fetch(:a)
      b = chars.fetch(:b)
      c = chars.fetch(:c)
      encoded_a = hex_escapes(a)
      encoded_b = hex_escapes(b)
      encoded_c = hex_escapes(c)

      one_char = "\\A(#{encoded_a}+)\\z".b
      add.call("one-encoded-character-match-#{encoding.downcase}", encoding,
               one_char, a + a)
      add.call("one-encoded-character-no-match-#{encoding.downcase}", encoding,
               one_char, b)

      two_char = "\\A(#{encoded_a}#{encoded_b}+)\\z".b
      add.call("two-encoded-characters-expected-#{encoding.downcase}", encoding,
               two_char, a + b + b)
      add.call("two-encoded-characters-contrasting-#{encoding.downcase}",
               encoding, two_char, a + b + a + b)
      add.call("two-encoded-characters-no-match-#{encoding.downcase}", encoding,
               two_char, a + c)

      mixed = "\\A(".b + a.pack("C*") + encoded_b + encoded_c + "+)\\z".b
      add.call("mixed-literal-escape-expected-#{encoding.downcase}", encoding,
               mixed, a + b + c + c)
      add.call("mixed-literal-escape-contrasting-#{encoding.downcase}",
               encoding, mixed, a + b + c + a + b + c)
      add.call("mixed-literal-escape-no-match-#{encoding.downcase}", encoding,
               mixed, a + b + c + a)
    end

    add.call("ascii-binary-control", "ASCII-8BIT", %q(\A(\x41\x42+)\z).b,
             [0x41, 0x42, 0x42])
    add.call("malformed-utf8-pattern", "UTF-8", %q(\A\xE3\x81\z).b,
             [0xE3, 0x81])
    add.call("malformed-utf8-subject", "UTF-8", %q(\A.\z).b, [0xFF])

    ["?", "*", "+", "{2}", "{2,3}"].each do |quantifier|
      %w[A AB ABB ABAB].each do |subject|
        pattern = "\\A(\\x41\\x42#{quantifier})\\z".b
        add.call("root-#{quantifier.delete("{} ,")}-#{subject.downcase}",
                 "UTF-8", pattern, subject.bytes)
      end
    end

    add.call("mixed-hex-octal-utf8", "UTF-8", %q(\xC3\251).b,
             [0xC3, 0xA9])
    add.call("mixed-octal-hex-utf8", "UTF-8", %q(\303\xA9).b,
             [0xC3, 0xA9])
    add.call("raw-continuation-windows-31j", "Windows-31J",
             [0x5C, 0x78, 0x38, 0x32, 0xA0].pack("C*"), [0x82, 0xA0])
    add.call("raw-continuation-euc-jp", "EUC-JP",
             [0x5C, 0x78, 0x41, 0x34, 0xA2].pack("C*"), [0xA4, 0xA2])

    raise "expected 88 frozen cases, got #{cases.length}" unless cases.length == 88

    cases
  end

  def hex_escapes(bytes)
    bytes.map { |byte| format("\\x%02X", byte) }.join.b
  end

  def encoded(bytes, encoding_name)
    bytes.pack("C*").force_encoding(Encoding.find(encoding_name))
  end

  def error_data
    yield
    nil
  rescue StandardError => e
    { class: e.class.name, message: e.message }
  end

  def ranges(match)
    return nil unless match

    (0...match.length).map do |index|
      first = match.bytebegin(index)
      last = match.byteend(index)
      first && last ? [first, last] : [-1, -1]
    end
  end

  def mri_result(entry)
    pattern = encoded(entry.fetch(:pattern_bytes), entry.fetch(:encoding))
    subject = encoded(entry.fetch(:subject_bytes), entry.fetch(:encoding))
    regexp = nil
    construction_error = error_data do
      regexp = ::Regexp.new(pattern, entry.fetch(:options))
    end
    return { construction_error: construction_error } if construction_error

    match = nil
    match_error = error_data { match = regexp.match(subject) }
    {
      construction_error: nil,
      match_error: match_error,
      status: match.nil? ? 0 : 1,
      raw_ranges: ranges(match),
      captures: match&.captures&.map { |capture| capture&.b&.bytes }
    }
  end
end

if ENV["ONIBI_CASE_EXPORT"] == "1"
  require "digest"
  require "rbconfig"

  cases = DecodedEscapeRepeatCases.build
  frozen_cases = cases.map do |entry|
    entry.merge(mri: DecodedEscapeRepeatCases.mri_result(entry))
  end
  canonical = JSON.generate(cases)
  output = ENV.fetch("ONIBI_CASE_OUTPUT")
  document = JSON.pretty_generate(
    runtime: RUBY_DESCRIPTION,
    argv: [RbConfig.ruby, $PROGRAM_NAME],
    input_sha256: Digest::SHA256.hexdigest(canonical),
    case_count: frozen_cases.length,
    cases: frozen_cases
  )
  File.write(output, "#{document}\n")
  puts "wrote #{frozen_cases.length} frozen cases to #{output}"
  exit 0
end

require "digest"
require "rbconfig"
require "tmpdir"
require "test_helper"

class DecodedEscapeRepeatTest < Minitest::Test
  CASES = DecodedEscapeRepeatCases.build.freeze
  ROOT = File.expand_path("../../..", __dir__).freeze
  TOKEN_PATH = File.join(ROOT, "ext/onibi/token.c").freeze
  TEST_PATH = File.expand_path(__FILE__).freeze

  def test_decoded_runs_match_mri_on_native_rseq
    results = CASES.map { |entry| result_for(entry) }
    differences = results.filter_map do |row|
      row.fetch(:differences).empty? ? nil : { id: row.fetch(:id), reasons: row.fetch(:differences) }
    end
    artifact = {
      source_revision: ENV.fetch("ONIBI_SOURCE_REVISION", "unknown"),
      runtime: RUBY_DESCRIPTION,
      argv: [RbConfig.ruby, $PROGRAM_NAME, *ARGV],
      environment: {
        ONIBI_SOURCE_REVISION: ENV["ONIBI_SOURCE_REVISION"],
        ONIBI_E2E_RESULTS_PATH: ENV["ONIBI_E2E_RESULTS_PATH"]
      },
      input_sha256: Digest::SHA256.hexdigest(JSON.generate(CASES)),
      source_hashes: {
        token_c: Digest::SHA256.file(TOKEN_PATH).hexdigest,
        test_file: Digest::SHA256.file(TEST_PATH).hexdigest
      },
      loaded_bundle: loaded_bundle,
      case_count: results.length,
      difference_count: differences.length,
      differences: differences,
      cases: results
    }
    output_path = ENV.fetch(
      "ONIBI_E2E_RESULTS_PATH",
      File.join(Dir.tmpdir, "onibi-decoded-escape-repeat-e2e-results.json")
    )
    File.write(output_path, "#{JSON.pretty_generate(artifact)}\n")

    assert_equal 88, results.length
    assert_empty differences, JSON.pretty_generate(differences)
  end

  private

  def result_for(entry)
    pattern = DecodedEscapeRepeatCases.encoded(
      entry.fetch(:pattern_bytes), entry.fetch(:encoding)
    )
    subject = DecodedEscapeRepeatCases.encoded(
      entry.fetch(:subject_bytes), entry.fetch(:encoding)
    )
    expected_regexp = nil
    expected_construction_error = DecodedEscapeRepeatCases.error_data do
      expected_regexp = ::Regexp.new(pattern, entry.fetch(:options))
    end
    actual_regexp = nil
    actual_construction_error = DecodedEscapeRepeatCases.error_data do
      actual_regexp = Onibi::Regexp.new(pattern, entry.fetch(:options))
    end
    differences = []
    expected = { construction_error: expected_construction_error }
    actual = { construction_error: actual_construction_error }

    if expected_construction_error
      differences << "pattern construction error differs from MRI" unless same_error?(expected_construction_error, actual_construction_error)
    elsif actual_construction_error
      differences << "Onibi rejected an MRI-valid pattern"
    else
      expected_match = nil
      expected_match_error = DecodedEscapeRepeatCases.error_data do
        expected_match = expected_regexp.match(subject)
      end
      actual_match = nil
      actual_match_error = DecodedEscapeRepeatCases.error_data do
        actual_match = actual_regexp.match(subject)
      end
      diagnostics = nil
      diagnostics_error = DecodedEscapeRepeatCases.error_data do
        diagnostics = actual_regexp.send(:__onibi_diagnostics__, subject)
      end
      expected.merge!(
        match_error: expected_match_error,
        status: expected_match.nil? ? 0 : 1,
        raw_ranges: DecodedEscapeRepeatCases.ranges(expected_match),
        captures: expected_match&.captures&.map { |capture| capture&.b&.bytes }
      )
      actual.merge!(
        match_error: actual_match_error,
        diagnostics_error: diagnostics_error,
        status: diagnostics && diagnostics[:status],
        raw_registers: diagnostics && diagnostics[:raw_registers],
        rseq: diagnostics && diagnostics[:rseq],
        fallback: diagnostics && diagnostics[:fallback],
        public_ranges: DecodedEscapeRepeatCases.ranges(actual_match),
        captures: actual_match&.captures&.map { |capture| capture&.b&.bytes }
      )

      if expected_match_error
        differences << "subject match error differs from MRI" unless same_error?(expected_match_error, actual_match_error)
      elsif actual_match_error
        differences << "public match raised for a valid MRI subject"
      end

      if expected_match_error
        differences << "invalid subject reached native diagnostics" unless diagnostics_error
      elsif diagnostics_error
        differences << "native diagnostics raised for a valid MRI subject"
      else
        differences << "native RSeq route is absent" unless diagnostics[:rseq]
        differences << "native fallback count is not zero" unless diagnostics[:fallback].zero?
        differences << "native status differs from MRI" unless diagnostics[:status] == expected[:status]
        differences << "native raw ranges differ from MRI" if expected_match && diagnostics[:raw_registers] != expected[:raw_ranges]
      end

      unless expected_match_error || actual_match_error
        if expected_match.nil? != actual_match.nil?
          differences << "public match presence differs from MRI"
        elsif expected_match
          differences << "public captures differ from MRI" unless actual[:captures] == expected[:captures]
          differences << "public byte ranges differ from MRI" unless actual[:public_ranges] == expected[:raw_ranges]
        end
      end
    end

    {
      id: entry.fetch(:id),
      encoding: entry.fetch(:encoding),
      options: entry.fetch(:options),
      pattern_bytes: entry.fetch(:pattern_bytes),
      subject_bytes: entry.fetch(:subject_bytes),
      mri: expected,
      onibi: actual,
      differences: differences
    }
  rescue StandardError => e
    {
      id: entry.fetch(:id),
      encoding: entry.fetch(:encoding),
      options: entry.fetch(:options),
      pattern_bytes: entry.fetch(:pattern_bytes),
      subject_bytes: entry.fetch(:subject_bytes),
      unexpected_error: { class: e.class.name, message: e.message },
      differences: ["unexpected E2E exception"]
    }
  end

  def same_error?(expected, actual)
    return false unless actual

    expected_class = expected.fetch(:class).sub(/\AOnibi::/, "")
    actual_class = actual.fetch(:class).sub(/\AOnibi::/, "")
    expected_class == actual_class && expected.fetch(:message) == actual.fetch(:message)
  end

  def loaded_bundle
    path = $LOADED_FEATURES.find do |feature|
      feature.include?("/onibi") &&
        [".bundle", ".so", ".dylib"].any? { |extension| feature.end_with?(extension) }
    end
    return { path: nil, sha256: nil } unless path

    { path: path, sha256: Digest::SHA256.file(path).hexdigest }
  end
end
