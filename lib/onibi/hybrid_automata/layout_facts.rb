# frozen_string_literal: true

module Onibi
  module HybridAutomata
    module CFG
      module Analysis
        module_function

        def layout_facts(ast)
          parts = ast.is_a?(AST::Sequence) ? ast.parts : [ast]
          parts = coalesce_layout_literals(parts)
          parts.filter_map do |node|
            case node
            when AST::Literal
              value = node.value.dup.freeze
              LayoutFact.new(:exact_literal, value.length, value[0], value[-1], value, 0).freeze
            when AST::CharacterClass
              value = node.value.dup.freeze
              LayoutFact.new(:first_byte_set, 1, nil, nil, value, 0).freeze
            when AST::Alternation
              values = node.branches.filter_map { |branch| literal_value(branch) }
              next if values.empty? || values.length != node.branches.length

              values = values.map(&:freeze).freeze
              LayoutFact.new(:ordered_alternation, values.map(&:length).min, values.map { |value| value[0] },
                             values.map { |value| value[-1] }, values, (0...values.length).to_a.freeze).freeze
            end
          end.freeze
        end

        def coalesce_layout_literals(parts)
          parts.each_with_object([]) do |part, result|
            if result.last.is_a?(AST::Literal) && part.is_a?(AST::Literal)
              result[-1] = AST::Literal.new(result.last.value + part.value)
            else
              result << part
            end
          end
        end

        def literal_value(node)
          return node.value if node.is_a?(AST::Literal)
          return unless node.is_a?(AST::Sequence) && node.parts.all? { |part| part.is_a?(AST::Literal) }

          node.parts.map(&:value).join
        end
      end
    end
  end
end
