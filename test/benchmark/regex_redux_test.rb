# frozen_string_literal: true

require "stringio"
require "test_helper"
require_relative "../../regex-redux"

class RegexReduxTest < Minitest::Test
  INPUT = ">ONE\nAGGG TAAA\n"

  def test_ruby_and_onibi_engines_produce_the_same_result
    ruby_result = RegexRedux.new(StringIO.new(INPUT), engine: :ruby).to_s
    onibi_result = RegexRedux.new(StringIO.new(INPUT), engine: :onibi).to_s

    assert_equal ruby_result, onibi_result
  end

  def test_engine_can_be_selected_by_name
    assert_instance_of RegexRedux::RubyEngine, RegexRedux.engine(:ruby)
    assert_instance_of RegexRedux::OnibiEngine, RegexRedux.engine(:onibi)
    assert_equal :ruby, RegexRedux.engine_name(["--ruby"])
    assert_equal :onibi, RegexRedux.engine_name(["--engine=onibi"])
    assert_equal :onibi, RegexRedux.engine_name(["--engine", "onibi"])
  end

  def test_script_does_not_use_threads_or_forked_pattern_count
    source = File.read(File.expand_path("../../regex-redux.rb", __dir__))

    refute_includes source, "Thread"
    refute_includes source, "forked_pattern_count"
    refute_includes source, "Process.fork"
  end
end
