# frozen_string_literal: true

module Onibi
  module V2
    module IRGen
      module YARVIR
        module_function

        def generate(dfa)
          generate_iseq(dfa)
        end

        def generate_iseq(dfa)
          raise Onibi::UnsupportedPattern, "MRI YARV is not available" unless defined?(RubyVM::InstructionSequence)

          RubyVM::InstructionSequence.compile(source_for(dfa))
        end

        def label_match?(input, offset, label)
          opcode, operand = label
          case opcode.to_sym
          when :match_literal
            value = operand.fetch(:fields).fetch(:value)
            input.byteslice(offset, value.bytesize) == value
          when :match_any, :match_class, :match_escape, :match_property
            offset < input.bytesize
          else
            true
          end
        end

        def label_width(label)
          opcode, operand = label
          return operand.fetch(:fields).fetch(:value).bytesize if opcode.to_sym == :match_literal

          1
        end

        def source_for(dfa)
          states = dfa.states.map do |state|
            transitions = dfa.transitions.filter_map do |(source, label), target|
              next unless source == state.id

              [label, target]
            end
            [state.id, state.accepting, transitions]
          end
          body = states.map { |state| state_source(state) }.join("\n")
          <<~RUBY
            ->(input) do
              offset = 0
              state = #{dfa.start_state.id}
              loop do
                case state
            #{body}
                else
                  return false
                end
              end
            end
          RUBY
        end

        def state_source(state)
          id, accepting, transitions = state
          lines = ["            when #{id}"]
          transitions.each do |label, target|
            literal = ruby_literal(serialize_label(label))
            lines << "              if Onibi::V2::IRGen::YARVIR.label_match?(input, offset, #{literal})"
            lines << "                offset += Onibi::V2::IRGen::YARVIR.label_width(#{literal})"
            lines << "                state = #{target}"
            lines << "                next"
            lines << "              end"
          end
          lines << (accepting ? "              return true" : "              return false")
          lines.join("\n")
        end

        def serialize_label(label)
          [label[0], serialize_operand(label[1])]
        end

        def serialize_operand(value)
          case value
          when Struct
            {
              type: value.class.name,
              fields: value.members.zip(value.to_a).to_h { |key, item| [key, serialize_operand(item)] }
            }
          when Array
            value.map { |item| serialize_operand(item) }
          when Hash
            value.transform_values { |item| serialize_operand(item) }
          else
            value
          end
        end

        def ruby_literal(value)
          value.inspect
        end
      end
    end
  end
end
