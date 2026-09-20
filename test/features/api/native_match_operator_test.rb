# frozen_string_literal: true

require "test_helper"

class NativeMatchOperatorTest < Minitest::Test
  def test_native_positions_without_mri_calls_or_match_data
    cases = [["a", "ba"], ["a", "z"], ["(a)", "ba"], ["(a)", "z"],
             ['(a)\1', "baa"], ['(a)\1', "ba"], ["", ""], ["é", "あé"]]
    expected = cases.map { |pattern, input| ::Regexp.new(pattern) =~ input }
    regexps = cases.map { |pattern, _| Onibi::Regexp.new(pattern) }
    originals = %i[match match? =~ ===].to_h { |name| [name, ::Regexp.instance_method(name)] }
    originals.each_key { |name| ::Regexp.define_method(name) { |*| raise "MRI called" } }
    trace = TracePoint.new(:c_return) do |event|
      raise "MatchData published" if event.return_value.is_a?(Onibi::MatchData)
    end
    trace.enable do
      cases.each_with_index do |(_, input), index|
        actual = regexps[index] =~ input
        expected[index].nil? ? assert_nil(actual) : assert_equal(expected[index], actual)
      end
    end
  ensure
    originals&.each { |name, method| ::Regexp.define_method(name, method) }
  end

  def test_native_success_retains_state_and_miss_clears_state
    regexp = Onibi::Regexp.new("(é)")
    /prior/.match("prior")
    before = $~
    assert_equal 1, regexp =~ "あé"
    assert_same before, $~
    assert_same before, Onibi::Regexp.last_match
    assert_equal "prior", $&
    assert_nil(regexp =~ "z")
    assert_nil $~
    assert_nil Onibi::Regexp.last_match
    assert_equal 1, regexp =~ "あé"
    assert_nil $~
  end

  def test_coercion_matches_mri_on_native_and_fallback_paths
    string_like = Object.new
    def string_like.to_str = "あxa"
    bad_string = Object.new
    def bad_string.to_str = 1
    ["xa", 'x\X'].each do |pattern|
      regexp = Onibi::Regexp.new(pattern)
      mri = ::Regexp.new(pattern)
      ["あxa", :あxa, string_like, nil].each do |input|
        expected = mri =~ input
        actual = regexp =~ input
        expected.nil? ? assert_nil(actual) : assert_equal(expected, actual)
      end
      [1, Object.new, false, bad_string].each do |input|
        assert_raises(TypeError) { mri =~ input }
        assert_raises(TypeError) { regexp =~ input }
      end
      /prior/.match("prior")
      before = $~
      assert_raises(TypeError) { regexp =~ 1 }
      assert_same before, $~
      assert_nil(regexp =~ nil)
      assert_nil $~
      assert_nil Onibi::Regexp.last_match
    end
  end

  def test_explicit_fallback_keeps_mri_position_and_backreferences
    ['x(?<letter>\X)', 'x\K(?<letter>\X)'].each do |pattern|
      regexp = Onibi::Regexp.new(pattern)
      mri = ::Regexp.new(pattern)
      expected = mri =~ "あxa"
      captures = $~.to_a
      /prior/.match("prior")
      assert_equal expected, regexp =~ "あxa"
      assert_instance_of ::MatchData, $~
      assert_equal captures, $~.to_a
      assert_equal "a", $~[:letter]
      assert_equal mri, $~.regexp
      assert_same $~, Onibi::Regexp.last_match
      assert_nil(regexp =~ "")
      assert_nil $~
      assert_nil Onibi::Regexp.last_match
    end
  end
end
