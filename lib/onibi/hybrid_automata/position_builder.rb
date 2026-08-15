# frozen_string_literal: true

module Onibi
  module HybridAutomata
    module CFG
      module Analysis
        class PositionBuilder
          Fragment = Data.define(:first, :last, :nullable)

          attr_reader :positions, :follow, :reach

          def initialize
            @positions = []
            @follow = Hash.new { |hash, key| hash[key] = [] }
            @reach = Hash.new { |hash, key| hash[key] = [] }
          end

          def build(node)
            case node
            when AST::Literal then literal(node)
            when AST::Group then captured_group(node)
            when AST::Sequence then sequence(node.parts.map { |part| build(part) })
            when AST::Alternation then alternatives(node.branches.map { |branch| build(branch) })
            when AST::Quantifier then quantified(node)
            else Fragment.new([], [], true)
            end
          end

          def sequence(fragments)
            result = Fragment.new([], [], true)
            fragments.each { |fragment| result = concatenate(result, fragment) }
            result
          end

          private

          def captured_group(node)
            start = @positions.length
            fragment = build(node.body)
            return fragment unless node.capture

            (start...@positions.length).each do |index|
              position = @positions.fetch(index)
              tags = (position.tags + [TagOperation.new(:start, node.number, position.id),
                                       TagOperation.new(:end, node.number, position.id)]).freeze
              @positions[index] = Position.new(position.id, position.symbol, position.operation, tags).freeze
            end
            fragment
          end

          def literal(node)
            ids = node.value.each_char.map do |character|
              id = @positions.length
              position = Position.new(id, character, node, [].freeze).freeze
              @positions << position
              @reach[character] << id
              id
            end
            ids.each_cons(2) { |left, right| @follow[left] << right }
            Fragment.new(ids.first ? [ids.first] : [], ids.last ? [ids.last] : [], ids.empty?)
          end

          def alternatives(fragments)
            Fragment.new(fragments.flat_map(&:first).uniq, fragments.flat_map(&:last).uniq,
                         fragments.all?(&:nullable))
          end

          def quantified(node)
            fragment = build(node.expression)
            repeat = node.maximum.nil? || node.maximum > 1
            fragment.last.product(fragment.first) { |left, right| @follow[left] << right } if repeat
            Fragment.new(fragment.first, fragment.last, node.minimum.zero? || fragment.nullable)
          end

          def concatenate(left, right)
            left.last.product(right.first) { |source, target| @follow[source] << target }
            first = left.first + (left.nullable ? right.first : [])
            last = right.last + (right.nullable ? left.last : [])
            Fragment.new(first.uniq, last.uniq, left.nullable && right.nullable)
          end
        end
      end
    end
  end
end
