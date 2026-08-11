# frozen_string_literal: true

module DifferentialHarness
  module_function

  def compare(fixture)
    mri = execute(::Regexp, fixture)
    onibi = execute(Onibi::Regexp, fixture)
    id = fixture_value(fixture, :id, fixture[:name] || fixture["name"])

    {
      id: id,
      name: id,
      mri: mri,
      onibi: onibi,
      equal: mri == onibi,
      support: support_classification(fixture),
      message: mismatch_message(id, fixture, mri, onibi)
    }
  end

  def execute(regexp_class, fixture)
    regexp = build_regexp(regexp_class, fixture)
    return { kind: :inventory } if fixture_value(fixture, :operation, :match?) == :inventory

    normalize(invoke(regexp, fixture))
  rescue StandardError => e
    normalize_error(e, :construct) if regexp.nil?
    normalize_error(e, :invoke)
  end

  def build_regexp(regexp_class, fixture)
    pattern = fixture_value(fixture, :pattern)
    options = fixture_value(fixture, :options)
    keywords = fixture_value(fixture, :constructor_keywords, {})

    arguments = options.nil? ? [pattern] : [pattern, options]
    keywords.empty? ? regexp_class.new(*arguments) : regexp_class.new(*arguments, **keywords)
  end

  def invoke(regexp, fixture)
    operation = fixture_value(fixture, :operation, :match?)
    return regexp.public_send(operation, **fixture_value(fixture, :keywords, {})) if operation == :timeout

    arguments = invocation_arguments(fixture, operation)
    keywords = fixture_value(fixture, :keywords, {})
    block = fixture_value(fixture, :block, false) ? proc { |value| value } : nil

    if keywords.empty?
      regexp.public_send(operation, *arguments,
                         &block)
    else
      regexp.public_send(operation, *arguments, **keywords, &block)
    end
  end

  def invocation_arguments(fixture, operation)
    arguments = fixture_value(fixture, :arguments, [])
    return arguments unless %i[match match?].include?(operation)

    input = fixture_value(fixture, :input)
    position = fixture_value(fixture, :position, :absent)
    position == :absent ? [input, *arguments] : [input, position, *arguments]
  end

  def normalize(result)
    return { kind: :nil } if result.nil?
    return { kind: :boolean, value: result } if [true, false].include?(result)
    return normalize_match(result) if result.is_a?(::MatchData) || result.is_a?(Onibi::MatchData)
    return normalize_regexp(result) if result.is_a?(::Regexp) || result.is_a?(Onibi::Regexp)
    return { kind: :encoding, value: result.name } if result.is_a?(Encoding)

    { kind: :value, value: normalize_value(result) }
  end

  def normalize_match(result)
    {
      kind: :match,
      full: result[0],
      captures: result.captures,
      offsets: (0..result.length - 1).map { |index| result.offset(index) },
      encoding: result.string.encoding.name,
      names: result.names,
      named_captures: result.named_captures,
      pre_match: result.pre_match,
      post_match: result.post_match
    }
  end

  def normalize_regexp(result)
    {
      kind: :regexp,
      source: result.source,
      options: result.options,
      encoding: result.encoding.name,
      fixed_encoding: result.fixed_encoding?,
      casefold: result.casefold?,
      inspect: result.inspect,
      to_s: result.to_s
    }
  end

  def normalize_value(value)
    return value.map { |item| normalize_value(item) } if value.is_a?(Array)
    if value.is_a?(Range)
      return { begin: normalize_value(value.begin), end: normalize_value(value.end),
               exclude_end: value.exclude_end? }
    end

    value
  end

  def normalize_error(error, call_site)
    {
      kind: :error,
      class: normalize_error_class(error),
      message: normalize_error_message(error),
      call_site: call_site
    }
  end

  def normalize_error_class(error)
    return "RegexpError" if error.is_a?(::RegexpError) || error.is_a?(Onibi::RegexpError)

    error.class.name
  end

  def normalize_error_message(error)
    return "regexp syntax error" if error.is_a?(::RegexpError) || error.is_a?(Onibi::RegexpError)
    return "incompatible encoding" if error.is_a?(Encoding::CompatibilityError)

    error.message.to_s.gsub(/\s+/, " ").strip
  end

  def support_classification(fixture)
    inventory = fixture_value(fixture, :inventory, {})
    status = fixture_value(inventory, :status, fixture_value(fixture, :status, "supported"))

    return :unsupported_by_design if status.to_s == "excluded"
    return :not_yet_implemented if status.to_s == "unsupported"
    return :partial if status.to_s == "partial"

    :supported
  end

  def mismatch_message(id, fixture, mri, onibi)
    "#{id}: pattern=#{fixture_value(fixture, :pattern).inspect}; " \
      "options=#{fixture_value(fixture, :options).inspect}; input=#{fixture_value(fixture, :input).inspect}; " \
      "expected=#{mri.inspect}; actual=#{onibi.inspect}"
  end

  def fixture_value(fixture, key, default = :missing)
    return fixture[key] if fixture.key?(key)
    return fixture[key.to_s] if fixture.key?(key.to_s)
    return default unless default == :missing

    fixture.fetch(key)
  end
end
