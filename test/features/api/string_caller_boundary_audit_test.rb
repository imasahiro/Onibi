# frozen_string_literal: true

require "test_helper"

# These checks record current boundaries. They do not define future support.
class StringCallerBoundaryAuditTest < Minitest::Test
  CASES = [["a", "aba"], ["(a)(z)?", "aba"], ["", "aba"],
           ["()", ""], ["z", "aba"]].freeze

  def test_string_callers_reject_native_and_fallback_patterns_without_changing_state
    ["(a)", '(\X)'].each do |pattern|
      regexp = Onibi::Regexp.new(pattern)
      %i[match match? scan split [] sub gsub].each do |method|
        args = %i[sub gsub].include?(method) ? [regexp, "x"] : [regexp]
        /(prior)/.match("prior")
        before = $~
        assert_raises(TypeError) { "aba".public_send(method, *args) }
        assert_same before, $~
        assert_same before, Onibi::Regexp.last_match
        assert_equal "prior", $1
      end
    end
  end

  def test_string_operator_delegates_with_native_and_fallback_state_rules
    ["(a)", '(\X)'].each do |pattern|
      regexp = Onibi::Regexp.new(pattern)
      expected = "あa" =~ ::Regexp.new(pattern)
      /(prior)/.match("prior")
      before = $~
      assert_equal expected, "あa" =~ regexp
      if pattern == "(a)"
        assert_same before, $~
      else
        assert_instance_of ::MatchData, $~
        refute_same before, $~
        assert_equal ["あ", "あ"], $~.to_a
      end
      assert_same $~, Onibi::Regexp.last_match
      assert_nil "" =~ regexp
      assert_nil $~
    end
  end

  def test_native_scan_values_and_ignored_blocks_preserve_state
    CASES.each do |pattern, input|
      expected = input.scan(::Regexp.new(pattern))
      regexp = Onibi::Regexp.new(pattern)
      /(prior)/.match("prior")
      before = $~
      assert_equal expected, regexp.scan(input)
      assert_same before, $~
      yielded = []
      assert_equal expected, regexp.scan(input) { |value| yielded << value }
      assert_empty yielded
      assert_same before, $~
      assert_same before, Onibi::Regexp.last_match
    end
  end

  def test_fallback_scan_ignores_blocks_but_publishes_mri_state
    ['\X', '(\X)'].each do |pattern|
      ["éあ", ""].each do |input|
        mri = ::Regexp.new(pattern)
        expected = input.scan(mri)
        captures = $~&.to_a
        [false, true].each do |with_block|
          /(prior)/.match("prior")
          before = $~
          regexp = Onibi::Regexp.new(pattern)
          yielded = []
          actual = if with_block
                     regexp.scan(input) { |value| yielded << value }
                   else
                     regexp.scan(input)
                   end
          assert_equal expected, actual
          assert_empty yielded
          if captures
            assert_instance_of ::MatchData, $~
            refute_same before, $~
            assert_equal captures, $~.to_a
            assert_equal mri, $~.regexp
          else
            assert_nil $~
          end
          $~ ? assert_same($~, Onibi::Regexp.last_match) : assert_nil(Onibi::Regexp.last_match)
        end
      end
    end
  end

  def test_native_gsub_values_and_blocks_preserve_state
    CASES.each do |pattern, input|
      mri = ::Regexp.new(pattern)
      expected = input.gsub(mri, "x")
      expected_yields = []
      input.gsub(mri) { |value| expected_yields << value; "x" }
      regexp = Onibi::Regexp.new(pattern)
      /(prior)/.match("prior")
      before = $~
      assert_equal expected, regexp.gsub(input, "x")
      assert_same before, $~
      yielded = []
      actual = regexp.gsub(input) do |value|
        yielded << value
        assert_same before, $~
        assert_same before, Onibi::Regexp.last_match
        "x"
      end
      assert_equal expected, actual
      assert_equal expected_yields, yielded
      assert_same before, $~
      refute_same input, actual
    end
  end

  def test_backslash_replacements_use_mri_state_even_for_native_patterns
    [["(a)", '\1'], ["(a)", '\&'], ["(?<letter>a)", '\k<letter>'],
     ["a", '\\\\'], ["a", '\q'], ["", '\&']].each do |pattern, replacement|
      ["aba", ""].each do |input|
        mri = ::Regexp.new(pattern)
        expected = input.gsub(mri, replacement)
        captures = $~&.to_a
        /(prior)/.match("prior")
        before = $~
        assert_equal expected, Onibi::Regexp.new(pattern).gsub(input, replacement)
        if captures
          assert_instance_of ::MatchData, $~
          refute_same before, $~
          assert_equal captures, $~.to_a
          assert_equal mri, $~.regexp
        else
          assert_nil $~
        end
        $~ ? assert_same($~, Onibi::Regexp.last_match) : assert_nil(Onibi::Regexp.last_match)
      end
    end
  end

  def test_fallback_gsub_forwards_blocks_and_publishes_mri_state
    ["éあ", ""].each do |input|
      mri = /(\X)/
      expected = input.gsub(mri, "x")
      captures = $~&.to_a
      [false, true].each do |with_block|
        /(prior)/.match("prior")
        before = $~
        regexp = Onibi::Regexp.new('(\X)')
        yielded = []
        actual = if with_block
                   regexp.gsub(input) do |value|
                     yielded << value
                     assert_instance_of ::MatchData, $~
                     refute_same before, $~
                     assert_equal value, $1
                     $~ ? assert_same($~, Onibi::Regexp.last_match) : assert_nil(Onibi::Regexp.last_match)
                     "x"
                   end
                 else
                   regexp.gsub(input, "x")
                 end
        assert_equal expected, actual
        assert_equal(with_block ? input.chars : [], yielded)
        if captures
          assert_instance_of ::MatchData, $~
          refute_same before, $~
          assert_equal captures, $~.to_a
        else
          assert_nil $~
        end
        $~ ? assert_same($~, Onibi::Regexp.last_match) : assert_nil(Onibi::Regexp.last_match)
      end
    end
  end

  def test_empty_pattern_on_multibyte_input_uses_mri_fallback
    regexp = Onibi::Regexp.new("")
    input = "éあ"
    expected_scan = input.scan(//)
    expected_gsub = input.gsub(//, "x")
    /(prior)/.match("prior")
    before = $~
    assert_equal expected_scan, regexp.scan(input)
    assert_instance_of ::MatchData, $~
    refute_same before, $~
    assert_same $~, Onibi::Regexp.last_match
    /(prior)/.match("prior")
    before = $~
    assert_equal expected_gsub, regexp.gsub(input, "x")
    assert_instance_of ::MatchData, $~
    refute_same before, $~
    assert_same $~, Onibi::Regexp.last_match
  end

  def test_missing_gsub_replacement_is_not_an_enumerator
    /(prior)/.match("prior")
    before = $~
    assert_raises(TypeError) { Onibi::Regexp.new("a").gsub("a") }
    assert_same before, $~
    assert_instance_of Enumerator, "a".gsub(/a/)
  end

  def test_native_scan_and_plain_gsub_do_not_call_string_adapters
    regexps = CASES.map { |pattern, input| [Onibi::Regexp.new(pattern), input] }
    originals = %i[scan gsub].to_h { |name| [name, String.instance_method(name)] }
    originals.each_key { |name| String.define_method(name) { |*| raise "String adapter called" } }
    regexps.each do |regexp, input|
      assert_instance_of Array, regexp.scan(input)
      assert_instance_of String, regexp.gsub(input, "x")
      assert_instance_of String, regexp.gsub(input) { "x" }
    end
  ensure
    originals&.each { |name, method| String.define_method(name, method) }
  end
end
