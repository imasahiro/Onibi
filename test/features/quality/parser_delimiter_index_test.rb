# frozen_string_literal: true

require_relative "../../test_helper"

class ParserDelimiterIndexTest < Minitest::Test
  EXTENSION_ROOT = File.join(PROJECT_ROOT, "ext", "onibi")

  def source_for(*files)
    files.map { |file| File.read(File.join(EXTENSION_ROOT, file)) }.join("\n")
  end

  def test_parser_uses_token_delimiter_indices
    source = source_for("token.c", "ast.c", "parser.c")
    parser = source_for("parser.c")

    refute_includes source, "onibi_c_find_close"
    assert_includes source, "onibi_token_index_delimiters"
    assert_includes source, "token->matching"
    assert_includes parser, "long close = token->matching"
    assert_equal 3, parser.scan("long close = token->matching").length
  end

  def test_nested_classes_and_adjacent_delimiters_scale_with_one_index_pass
    open_class = "["
    close_class = "]"
    nested = "#{open_class * 32}a#{close_class * 32}"
    adjacent = "[a]" * 128

    assert Onibi::Regexp.new(nested).match?("a")
    assert Onibi::Regexp.new(adjacent).match?("a" * 128)
  end

  def test_nested_groups_and_unmatched_delimiters_keep_parser_errors
    open_class = "["
    open_group = "("
    close_group = ")"
    nested = "#{open_group * 8}a#{close_group * 8}"
    unmatched_group = "#{open_group * 8}a"
    unmatched_class = "#{open_class * 8}a"
    assert Onibi::Regexp.new(nested).match?("a")

    assert_raises(Onibi::RegexpError) { Onibi::Regexp.new(unmatched_group) }
    assert_raises(Onibi::RegexpError) { Onibi::Regexp.new(unmatched_class) }
  end

  def test_index_pass_does_not_define_the_nesting_boundary
    source = source_for("token.c")
    indexer = source[/static void\s+onibi_token_index_delimiters\(.*?^}\n/m]

    refute_nil indexer
    refute_includes indexer, "regexp nesting is too deep"
    assert_includes source, "regexp nesting is too deep"
  end
end
