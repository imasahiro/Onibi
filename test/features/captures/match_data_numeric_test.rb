# frozen_string_literal: true

require "test_helper"

class MatchDataNumericTest < Minitest::Test
  def payload(regexp, subject, ranges)
    Onibi::MatchData.send(:__onibi_new__, regexp, subject, ranges)
  end

  def fixture(source = "(a)(b)?", subject = "a", options = 0)
    mri_regexp = ::Regexp.new(source, options)
    mri = mri_regexp.match(subject)
    onibi_regexp = Onibi::Regexp.new(source, options)
    ranges = mri.length.times.map do |index|
      begin_offset, end_offset = mri.offset(index)
      if begin_offset.nil?
        [-1, -1]
      else
        [subject[0, begin_offset].bytesize, subject[0, end_offset].bytesize]
      end
    end
    [mri, payload(onibi_regexp, subject, ranges)]
  end

  def value_shape(value)
    case value
    when String
      [:string, value.bytes, value.encoding.name, value.frozen?]
    when Array
      value.map { |item| value_shape(item) }
    else
      value
    end
  end

  def result(callable)
    [:value, value_shape(callable.call)]
  rescue StandardError => e
    [:error, e.class, e.message]
  end

  def assert_differential(mri, onibi, &callable)
    assert_equal result(-> { callable.call(mri) }),
                 result(-> { callable.call(onibi) })
  end

  def test_integer_and_slice_selection_matches_mri
    mri, onibi = fixture
    invalid_endpoint = Object.new
    invalid_endpoint.define_singleton_method(:<=>) { |_other| 0 }
    invalid_endpoint.define_singleton_method(:to_int) { raise TypeError, "bad int" }
    invalid_range = Range.new(invalid_endpoint, 2)

    [-5, -4, -3, -2, -1, 0, 1, 2, 3, 4, 1.9, Float::INFINITY,
     Float::NAN, 2**40, -(2**40), nil].each do |index|
      assert_differential(mri, onibi) { |match_data| match_data[index] }
    end

    [[-5, 0], [-3, 0], [-3, 2], [-2, 2], [-1, 2], [0, 2], [3, 1],
     [4, 0], [1, -1], [0, 2**40], [2**40, 0], ["x", 1], [1, "x"],
     [1, nil], [1, 1.9], [1, Float::NAN], [0..2, nil], [..1, nil],
     [1.., nil], [1.9..2.9, nil], [invalid_range, nil]].each do |arguments|
      assert_differential(mri, onibi) { |match_data| match_data[*arguments] }
    end
  end

  def test_range_selection_matches_mri
    mri, onibi = fixture
    ranges = [0...2, 0..2, 1.., ..1, -2.., ..-1, 2..1, 100..200,
              1.9..2.9, 1.2.., ..2.9, -(2**40).., 1..2**40]

    ranges.each do |range|
      assert_differential(mri, onibi) { |match_data| match_data[range] }
    end
  end

  def test_integer_like_conversion_and_error_order_match_mri
    to_int = lambda do |value|
      object = Object.new
      object.define_singleton_method(:to_int) { value }
      object
    end
    raising = lambda do
      object = Object.new
      object.define_singleton_method(:to_int) { raise TypeError, "bad int" }
      object
    end
    mri, onibi = fixture

    [to_int.call(1), to_int.call("bad"), raising.call].each do |index|
      assert_differential(mri, onibi) { |match_data| match_data[index] }
      assert_differential(mri, onibi) { |match_data| match_data[index, 1] }
    end
  end

  def test_capture_arrays_and_snapshot_strings_match_mri
    mri, onibi = fixture("(?<word>é)", "xxéyy")

    %i[to_a captures size length to_s pre_match post_match].each do |method|
      assert_differential(mri, onibi) { |match_data| match_data.public_send(method) }
    end
    assert_equal value_shape(mri.string), value_shape(onibi.string)
    assert_equal mri.regexp.source, onibi.regexp.source

    subject = String.new("xxéyy")
    _, snapshot = fixture("(?<word>é)", subject)
    subject.replace("changed")
    assert_equal "xxéyy", snapshot.string
    assert_predicate snapshot.string, :frozen?
    assert_raises(FrozenError) { snapshot.string << "!" }
    assert_equal "é", snapshot.to_s
    assert_equal "xx", snapshot.pre_match
    assert_equal "yy", snapshot.post_match
    snapshot.to_s << "!"
    snapshot.pre_match << "!"
    snapshot.post_match << "!"
    assert_equal "é", snapshot.to_s
  end

  def test_binary_subject_and_capture_outside_group_zero_match_mri
    subject = "\xffa".b
    mri, onibi = fixture("(?=(a))", subject, ::Regexp::NOENCODING)

    assert_equal value_shape(mri.to_a), value_shape(onibi.to_a)
    [0, 1, -1, 0..1, ..1, 1..].each do |selector|
      assert_differential(mri, onibi) { |match_data| match_data[selector] }
    end
    assert_equal value_shape(mri.string), value_shape(onibi.string)
  end
end
