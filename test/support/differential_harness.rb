# frozen_string_literal: true

module DifferentialHarness
  module_function

  def compare(fixture)
    mri = execute(::Regexp, fixture)
    onibi = execute(Onibi::Regexp, fixture)
    equal = mri == onibi

    {
      name: fixture.fetch(:name),
      mri: mri,
      onibi: onibi,
      equal: equal,
      message: mismatch_message(fixture, mri, onibi)
    }
  end

  def execute(regexp_class, fixture)
    regexp = build_regexp(regexp_class, fixture)
    normalize(regexp.public_send(fixture.fetch(:operation, :match?), fixture.fetch(:input)))
  rescue StandardError => e
    { kind: :error, class: e.class.name, message: normalize_error(e.message) }
  end

  def build_regexp(regexp_class, fixture)
    options = fixture.fetch(:options)

    options.nil? ? regexp_class.new(fixture.fetch(:pattern)) : regexp_class.new(fixture.fetch(:pattern), options)
  end

  def normalize(result)
    return { kind: :nil } if result.nil?
    return { kind: :boolean, value: result } if [true, false].include?(result)

    {
      kind: :match,
      full: result[0],
      captures: result.captures,
      offsets: (0..result.length - 1).map { |index| result.offset(index) }
    }
  end

  def normalize_error(message)
    message.to_s.gsub(/\s+/, " ").strip
  end

  def mismatch_message(fixture, mri, onibi)
    "#{fixture.fetch(:name)}: MRI=#{mri.inspect}; Onibi=#{onibi.inspect}"
  end
end
