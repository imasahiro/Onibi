# frozen_string_literal: true

require "test_helper"

class ScanBlockTest < Minitest::Test
  CASES = [["a", "aba"], ["(a)(z)?", "aba"], ["", "aba"],
           ["()", ""], ["z", "aba"], ["(é)", "éあé"],
           ["(?=é)", "éé"], ["", "éあ"], ['\X', "éあ"],
           ['(\X)', "éあ"], ['\X', ""]].freeze

  def test_block_values_and_original_subject_match_mri
    CASES.each do |pattern, source|
      input = source.dup
      expected = []
      assert_same input, input.scan(::Regexp.new(pattern)) { |value| expected << value }
      actual = []
      assert_same input, Onibi::Regexp.new(pattern).scan(input) { |value| actual << value }
      assert_equal expected, actual, pattern
    end
  end

  def test_native_blocks_keep_mri_backreference_identity
    ["a", "(a)", "", "z"].each do |pattern|
      /(prior)/.match("prior")
      before = $~
      Onibi::Regexp.new(pattern).scan("aba") do |_value|
        assert_same before, $~
        assert_same before, Onibi::Regexp.last_match
        assert_equal "prior", $1
      end
      assert_same before, $~
    end
  end

  def test_fallback_blocks_receive_mri_backreferences
    Onibi::Regexp.new('(\X)').scan("éあ") do |value|
      assert_instance_of ::MatchData, $~
      assert_equal value, $~.captures
      assert_same $~, Onibi::Regexp.last_match
    end
  end

  def test_subject_mutations_raise_before_another_yield
    mutations = [->(str) { str << "more" }, ->(str) { str.clear }]
    ["a", "(a)", "", '\X'].each do |pattern|
      mutations.each do |mutation|
        [false, true].each do |native|
          input = +"aa"
          count = 0
          error = assert_raises(RuntimeError) do
            block = proc { count += 1; mutation.call(input) }
            if native
              Onibi::Regexp.new(pattern).scan(input, &block)
            else
              input.scan(::Regexp.new(pattern), &block)
            end
          end
          assert_equal "string modified", error.message
          assert_equal 1, count
        end
      end
    end
  end

  def test_same_length_byte_changes_match_mri
    [->(str) { str.replace("zz") }, ->(str) { str.setbyte(0, 122) }].each do |mutation|
      ["a", "(a)", "", '\X', '(\X)'].each do |pattern|
        expected_input = +"aa"
        expected = []
        assert_same expected_input, expected_input.scan(::Regexp.new(pattern)) { |value|
          expected << value
          mutation.call(expected_input)
        }
        input = +"aa"
        actual = []
        assert_same input, Onibi::Regexp.new(pattern).scan(input) { |value|
          actual << value
          mutation.call(input)
        }
        assert_equal expected, actual, pattern
        assert_equal expected_input, input, pattern
      end
    end
  end

  def test_encoding_change_is_rejected
    ["a", '\X'].each do |pattern|
      input = +"aa"
      error = assert_raises(RuntimeError) do
        Onibi::Regexp.new(pattern).scan(input) { input.force_encoding(Encoding::BINARY) }
      end
      assert_equal "string modified", error.message
    end
  end

  def test_heap_subject_mutation_and_final_empty_match_are_checked
    [["a", "a" * 100], ["()", ""]].each do |pattern, source|
      input = source.dup
      regexp = Onibi::Regexp.new(pattern)
      error = assert_raises(RuntimeError) do
        regexp.scan(input) { input << "changed" }
      end
      assert_equal "string modified", error.message
      assert_equal source.scan(::Regexp.new(pattern)), regexp.scan(source)
    end
  end

  def test_subject_coercion_returns_the_original_string
    input = +"aa"
    wrapper = Object.new
    wrapper.define_singleton_method(:to_str) { input }
    ["a", '\X'].each do |pattern|
      assert_same input, Onibi::Regexp.new(pattern).scan(wrapper) { |_| }
    end
  end

  def test_block_exception_and_nonlocal_exit_leave_scan_usable
    ["a", "(a)", "", '\X'].each do |pattern|
      regexp = Onibi::Regexp.new(pattern)
      expected = "aa".scan(::Regexp.new(pattern))
      error = Class.new(StandardError).new("block failed")
      20.times do
        assert_same error, assert_raises(error.class) { regexp.scan("aa") { raise error } }
        assert_equal :stopped, regexp.scan("aa") { break :stopped }
        assert_equal :thrown, catch(:stop) { regexp.scan("aa") { throw :stop, :thrown } }
        assert_equal expected, regexp.scan("aa")
      end
    end
    GC.start
  end

  def test_reentrant_scan_and_gc_keep_outer_ranges_valid
    regexp = Onibi::Regexp.new("(a)(z)?")
    values = []
    input = +"aba"
    assert_same input, regexp.scan(input) { |value|
      GC.start
      assert_equal [["a", nil]], regexp.scan("a")
      values << value
    }
    assert_equal [["a", nil], ["a", nil]], values
  end

  def test_gc_compaction_keeps_a_shared_subject_snapshot_valid
    input = "ab" * 40
    values = []
    assert_same input, Onibi::Regexp.new("(a)").scan(input) { |value|
      GC.verify_compaction_references(double_heap: true, toward: :empty)
      values << value
    }
    assert_equal input.scan(/(a)/), values
  end
end
