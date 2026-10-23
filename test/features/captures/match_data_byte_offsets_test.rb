# frozen_string_literal: true

require "test_helper"

class MatchDataByteOffsetsTest < Minitest::Test
  def payload(source, subject)
    mri_regexp = ::Regexp.new(source)
    mri = mri_regexp.match(subject)
    ranges = mri.length.times.map do |index|
      begin_offset, end_offset = mri.offset(index)
      if begin_offset.nil?
        [-1, -1]
      else
        [subject[0, begin_offset].bytesize, subject[0, end_offset].bytesize]
      end
    end
    [mri, Onibi::MatchData.send(:__onibi_new__, Onibi::Regexp.new(source),
                                subject, ranges)]
  end

  def result(callable)
    [:value, callable.call]
  rescue StandardError => e
    [:error, e.class, e.message]
  end

  def assert_differential(mri, onibi, method, *arguments)
    assert_equal result(-> { mri.public_send(method, *arguments) }),
                 result(-> { onibi.public_send(method, *arguments) })
  end

  def test_numeric_byte_offsets_match_mri_without_character_conversion
    mri, onibi = payload("(?<word>é)(b)?", "xxéyy")

    [0, 1, 2, 0.9, 1.9, -0.1].each do |selector|
      %i[bytebegin byteend byteoffset].each do |method|
        assert_differential(mri, onibi, method, selector)
      end
    end
    assert_equal [2, 4], onibi.byteoffset(0)
    assert_equal [2, 4], onibi.byteoffset("word")
  end

  def test_named_duplicate_and_unmatched_selectors_follow_mri
    [
      ["(?<word>a)(?<word>b)?", "a"],
      ["(?<word>a)(?<word>b)?", "ab"],
      ["(?<word>a)?(?<word>b)?", "x"],
      ["(?<empty>)(?<missing>a)?", ""]
    ].each do |source, subject|
      mri, onibi = payload(source, subject)
      %w[word empty missing].each do |selector|
        %i[bytebegin byteend byteoffset].each do |method|
          assert_differential(mri, onibi, method, selector)
          assert_differential(mri, onibi, method, selector.to_sym)
        end
      end
    end
  end

  def test_invalid_numeric_selectors_and_arity_match_mri
    mri, onibi = payload("(a)", "a")
    selectors = [-1, 2, -(2**40), 2**40, Float::NAN, Float::INFINITY,
                 -Float::INFINITY, nil, 1..2]
    selectors.each do |selector|
      %i[bytebegin byteend byteoffset].each do |method|
        assert_differential(mri, onibi, method, selector)
      end
    end

    integer_like = Object.new
    integer_like.define_singleton_method(:to_int) { 1 }
    raising = Object.new
    raising.define_singleton_method(:to_int) { raise TypeError, "bad int" }
    [integer_like, raising].each do |selector|
      %i[bytebegin byteend byteoffset].each do |method|
        assert_differential(mri, onibi, method, selector)
      end
    end

    %i[bytebegin byteend byteoffset].each do |method|
      assert_raises(ArgumentError) { onibi.public_send(method) }
      assert_raises(ArgumentError) { onibi.public_send(method, 0, 1) }
    end
  end

  def test_byte_offsets_are_fresh_and_keep_raw_registers
    subject = String.new("xxéyy")
    _mri, onibi = payload("(?<word>é)", subject)
    subject.replace("changed")
    GC.start
    GC.compact

    first = onibi.byteoffset(0)
    second = onibi.byteoffset(0)
    refute_same first, second
    first[0] = 99
    assert_equal [2, 4], onibi.byteoffset(0)
    assert_equal 2, onibi.bytebegin(:word)
    assert_equal 4, onibi.byteend(:word)
  end

  def test_binary_and_capture_outside_group_zero_use_byte_registers
    subject = "\xffa".b
    mri, onibi = payload("(?=(a))", subject)
    assert_equal [mri.bytebegin(0), mri.byteend(0)], onibi.byteoffset(0)
    assert_equal [mri.bytebegin(1), mri.byteend(1)], onibi.byteoffset(1)
    assert_equal [1, 1], onibi.byteoffset(0)
    assert_equal [1, 2], onibi.byteoffset(1)
  end
end
