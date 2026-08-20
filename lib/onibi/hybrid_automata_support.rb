# frozen_string_literal: true

module Onibi
  module HybridAutomata
    # Derives literals used by the HFA candidate-event policy.
    module PatternFacts
      module_function

      def selective_prefix(node)
        prefix = leading_literal(node)
        prefix if prefix && prefix.bytesize >= 2
      end

      def required_literal_specs(node)
        return unless node.is_a?(AST::Alternation) && node.branches.length > 1

        specs = node.branches.map do |branch|
          parts = branch.is_a?(AST::Sequence) ? branch.parts : [branch]
          offset = 0
          best = nil
          parts.each do |part|
            if part.is_a?(AST::Literal)
              best = [part.value, offset] if best.nil? || part.value.bytesize > best[0].bytesize
              offset += part.value.bytesize
            elsif part.is_a?(AST::CharacterClass)
              offset += 1
            else
              best = nil
              break
            end
          end
          best && best[0].ascii_only? && best[0].bytesize >= 3 ? best : nil
        end
        return unless specs.all?

        specs.map { |literal, offset| RequiredLiteralSpec.new(literal, offset) }.freeze
      end

      def trailing_literal(node)
        return node.value if node.is_a?(AST::Literal)
        return unless node.is_a?(AST::Sequence)

        value = +""
        node.parts.reverse_each do |part|
          break unless part.is_a?(AST::Literal)

          value.prepend(part.value)
        end
        value.empty? ? nil : value.freeze
      end

      def linebreak_spec(node)
        parts = node.is_a?(AST::Sequence) ? node.parts : [node]
        return unless parts.one? && parts.first.is_a?(AST::Escape) && parts.first.kind == :linebreak

        LinebreakSpec.new(true).freeze
      end

      def scoped_option_group?(node)
        return true if node.is_a?(AST::OptionGroup)

        children = case node
                   when AST::Sequence then node.parts
                   when AST::Alternation then node.branches
                   when AST::Group, AST::AtomicGroup then [node.body]
                   when AST::Quantifier then [node.expression]
                   else []
                   end
        children.any? { |child| child && scoped_option_group?(child) }
      end

      def leading_literal(node)
        return node.value if node.is_a?(AST::Literal)
        return unless node.is_a?(AST::Sequence)

        value = +""
        node.parts.each do |part|
          break unless part.is_a?(AST::Literal)

          value << part.value
        end
        value.empty? ? nil : value.freeze
      end

      def literal_value(node)
        return node.value if node.is_a?(AST::Literal)
        return unless node.is_a?(AST::Sequence) && node.parts.all? { |part| part.is_a?(AST::Literal) }

        node.parts.map(&:value).join.freeze
      end
    end

    # Extracts the absolute anchors supported by the HFA subset.
    module AnchorFacts
      private

      def extract_start_match(ast)
        parts = ast.is_a?(AST::Sequence) ? ast.parts.dup : [ast]
        start_match = parts.first.is_a?(AST::Escape) && parts.first.kind == :start_match
        parts.shift if start_match
        [anchor_body(parts), start_match]
      end

      def extract_anchors(ast)
        parts = ast.is_a?(AST::Sequence) ? ast.parts.dup : [ast]
        anchored_start = absolute_anchor?(parts.first, :anchor_absolute_start)
        parts.shift if anchored_start
        line_anchor_start = absolute_anchor?(parts.first, :anchor_start)
        parts.shift if line_anchor_start
        anchored_end = absolute_anchor?(parts.last, :anchor_absolute_end)
        parts.pop if anchored_end
        before_final_newline = absolute_anchor?(parts.last, :anchor_before_final_newline)
        parts.pop if before_final_newline
        line_anchor_end = absolute_anchor?(parts.last, :anchor_end)
        parts.pop if line_anchor_end
        raise UnsupportedPattern, "only leading \\A and trailing \\z/\\Z anchors are supported" if
          parts.any? { |part| part.is_a?(AST::Anchor) }

        [anchor_body(parts), anchored_start, anchored_end, before_final_newline, line_anchor_start, line_anchor_end]
      end

      def absolute_anchor?(node, kind)
        node.is_a?(AST::Anchor) && node.kind == kind
      end

      def anchor_body(parts)
        return AST::Sequence.new([]) if parts.empty?
        return parts.first if parts.length == 1

        AST::Sequence.new(parts)
      end
    end

    # Extracts edge assertions that can be checked around a candidate match.
    module GuardFacts
      private

      def extract_guards(ast)
        parts = ast.is_a?(AST::Sequence) ? ast.parts.dup : [ast]
        positive_prefix = guard_literal(parts.first, :positive) ||
                          guard_literal(parts.first, :positive_lookbehind)
        parts.shift if positive_prefix
        negative_prefix = guard_literal(parts.first, :negative_lookbehind)
        parts.shift if negative_prefix
        positive_suffix = guard_literal(parts.last, :positive)
        parts.pop if positive_suffix
        negative_suffix = guard_literal(parts.last, :negative)
        parts.pop if negative_suffix
        body = if parts.empty?
                 AST::Sequence.new([])
               elsif parts.length == 1
                 parts.first
               else
                 AST::Sequence.new(parts)
               end
        [body, positive_prefix, positive_suffix, negative_prefix, negative_suffix]
      end

      def guard_literal(node, kind)
        return unless node.is_a?(AST::Assertion) && node.kind == kind

        PatternFacts.literal_value(node.body) || node.body
      end
    end

    # Extracts word-boundary assertions that can be checked at match edges.
    module BoundaryFacts
      private

      def extract_boundaries(ast)
        parts = ast.is_a?(AST::Sequence) ? ast.parts.dup : [ast]
        start_boundary = boundary?(parts.first)
        parts.shift if start_boundary
        end_boundary = boundary?(parts.last)
        parts.pop if end_boundary
        raise UnsupportedPattern, "internal word boundaries are outside HFA subset" if parts.any? { |part| part.is_a?(AST::Escape) && boundary?(part) }

        body = if parts.empty?
                 AST::Sequence.new([])
               else
                 (parts.length == 1 ? parts.first : AST::Sequence.new(parts))
               end
        [body, start_boundary, end_boundary]
      end

      def boundary?(node)
        node.kind if node.is_a?(AST::Escape) && %i[word_boundary not_word_boundary].include?(node.kind)
      end
    end

    # Reconstructs regular topology from the optimized CFG's flow edges.
    module CfgTopology
      module_function

      def ast(cfg)
        blocks = cfg.blocks.to_h { |block| [block.id, block] }
        parse_sequence(blocks, cfg.entry, nil, [])
      end

      def parse_sequence(blocks, id, stop, active)
        return AST::Sequence.new([]) if stop && id == stop
        raise UnsupportedPattern, "CFG contains a cycle outside a quantifier" if active.include?(id)

        block = blocks.fetch(id)
        active += [id]
        prefix = AST::Sequence.new(block.operations.reject { |operation| operation.opcode == :epsilon }
                                   .map(&:operand))
        case block.terminator.opcode
        when :return
          prefix
        when :jump
          target = only_successor(block)
          concat(prefix, parse_sequence(blocks, target, stop, active))
        when :choice
          merge = choice_merge(blocks, block)
          branches = block.successors.map do |edge|
            parse_sequence(blocks, edge.target, merge, active)
          end
          concat(prefix, AST::Alternation.new(branches), parse_sequence(blocks, merge, stop, active))
        else
          raise UnsupportedPattern, "CFG terminator #{block.terminator.opcode.inspect} is outside HFA subset"
        end
      end

      def only_successor(block)
        return block.successors.first.target if block.successors.one?

        raise UnsupportedPattern, "CFG jump has unexpected successor count"
      end

      def choice_merge(blocks, block)
        exits = block.successors.map { |edge| linear_exit(blocks, edge.target) }
        return exits.first if exits.one? && exits.first
        return exits.first if exits.uniq.one? && exits.first

        raise UnsupportedPattern, "CFG choice has no unique merge block"
      end

      def linear_exit(blocks, id)
        block = blocks.fetch(id)
        return id if block.terminator.opcode == :return
        return only_successor(block) if block.terminator.opcode == :jump
        return if block.terminator.opcode == :choice

        raise UnsupportedPattern, "CFG terminator #{block.terminator.opcode.inspect} is outside HFA subset"
      end

      def concat(*nodes)
        parts = nodes.flat_map { |node| node.is_a?(AST::Sequence) ? node.parts : [node] }
        AST::Sequence.new(parts)
      end
    end

    # Removes regular-language-neutral control nodes before position-NFA build.
    module RegularNormalizer
      module_function

      NEVER = Object.new.freeze

      def normalize(ast)
        groups = {}
        collect_groups(ast, groups)
        normalize_node(ast, groups)
      end

      def collect_groups(node, groups)
        case node
        when AST::Group
          groups[node.name || node.number] = node.body
          collect_groups(node.body, groups)
        when AST::Sequence
          node.parts.each { |part| collect_groups(part, groups) }
        when AST::Alternation
          node.branches.each { |branch| collect_groups(branch, groups) }
        when AST::Quantifier
          collect_groups(node.expression, groups)
        end
      end

      def normalize_node(node, groups)
        case node
        when AST::Sequence then normalize_sequence(node.parts, groups)
        when AST::Alternation
          branches = node.branches.filter_map do |branch|
            normalized = normalize_node(branch, groups)
            normalized unless normalized.equal?(NEVER)
          end
          return NEVER if branches.empty?
          return branches.first if branches.one?

          AST::Alternation.new(branches)
        when AST::Group then normalize_node(node.body, groups)
        when AST::AtomicGroup then normalize_node(node.body, groups)
        when AST::SubexpressionCall
          body = groups[node.identifier]
          raise UnsupportedPattern, "unresolved subexpression call" unless body

          normalize_node(body, groups)
        when AST::Conditional
          AST::Alternation.new([normalize_node(node.yes_branch, groups), normalize_node(node.no_branch, groups)])
        when AST::Assertion
          body = normalize_node(node.body, groups)
          return NEVER if node.kind == :negative && empty_sequence?(body)
          return body unless %i[negative negative_lookbehind positive].include?(node.kind)

          AST::Assertion.new(body, node.kind)
        when AST::Absence
          AST::Quantifier.new(AST::Any.new(nil), :*, 0, nil, :greedy)
        when AST::Quantifier
          AST::Quantifier.new(normalize_node(node.expression, groups), node.kind, node.minimum,
                              node.maximum, %i[possessive possessive_bounded].include?(node.mode) ? :greedy : node.mode)
        when AST::Escape
          node.kind == :match_reset ? nil : node
        else
          node
        end
      end

      def normalize_sequence(parts, groups)
        normalized = []
        parts.each_with_index do |part, index|
          if part.is_a?(AST::Conditional)
            normalized.pop
            raw_previous = parts[index - 1]
            if optional_capture?(raw_previous, part.condition)
              yes = AST::Sequence.new([raw_previous.expression.body, part.yes_branch])
              normalized << AST::Alternation.new([normalize_node(yes, groups), normalize_node(part.no_branch, groups)])
              next
            end
            normalized << normalize_node(part, groups)
            next
          end

          value = normalize_node(part, groups)
          return NEVER if value.equal?(NEVER)

          normalized << value if value
        end
        AST::Sequence.new(normalized.flat_map { |node| node.is_a?(AST::Sequence) ? node.parts : [node] })
      end

      def empty_sequence?(node)
        node.is_a?(AST::Sequence) && node.parts.empty?
      end

      def optional_capture?(node, condition)
        return false unless node.is_a?(AST::Quantifier) && node.kind == :"?" && node.minimum.zero?
        return false unless node.expression.is_a?(AST::Group)

        identifier = Array(condition).first
        node.expression.number == identifier.to_i || node.expression.name.to_s == identifier.to_s
      end
    end

    # Derives specialized metadata from the normalized compiler AST.
    module CompilerFacts
      ASCII_PROPERTY_TABLE_CACHE = {}
      ASCII_PROPERTY_TABLE_MUTEX = Mutex.new

      private

      def unicode_spec(ast)
        quantifier = if ast.is_a?(AST::Sequence) && ast.parts.one?
                       ast.parts.first
                     else
                       ast
                     end
        return unless quantifier.is_a?(AST::Quantifier)
        return unless %i[+ * bounded].include?(quantifier.kind)

        expression = quantifier.expression
        return unless expression.is_a?(AST::CharacterClass) || expression.is_a?(AST::Property)

        kind = expression.is_a?(AST::Property) ? :property : :class
        value = expression.is_a?(AST::Property) ? [expression.name, expression.negated] : expression.value
        UnicodeSpec.new(kind, value, quantifier.minimum, quantifier.maximum)
      end

      def repeated_literal_value(ast)
        quantifier = ast.is_a?(AST::Sequence) && ast.parts.one? ? ast.parts.first : ast
        return unless quantifier.is_a?(AST::Quantifier) && quantifier.kind == :+

        literal_value(quantifier.expression)
      end

      def repeat_literal_spec(ast)
        return if ignorecase?

        parts = ast.is_a?(AST::Sequence) ? ast.parts : [ast]
        return unless parts.length == 2
        return unless parts.first.is_a?(AST::Quantifier) && parts.first.kind == :+
        return unless parts.first.expression.is_a?(AST::Literal) && parts.first.expression.value.bytesize == 1
        return unless parts.last.is_a?(AST::Literal) && parts.last.value.ascii_only?

        RepeatLiteralSpec.new(parts.first.expression.value.getbyte(0), parts.last.value)
      end

      def possessive_literal_spec(ast)
        parts = ast.is_a?(AST::Sequence) ? ast.parts : [ast]
        return unless parts.length <= 2

        quantifier = parts.first
        return unless quantifier.is_a?(AST::Quantifier) &&
                      %i[possessive possessive_bounded].include?(quantifier.mode)
        return unless quantifier.expression.is_a?(AST::Literal) && quantifier.expression.value.ascii_only?
        return unless %i[+ *].include?(quantifier.kind)

        suffix = parts.length == 2 ? parts.last : AST::Literal.new("")
        return unless suffix.is_a?(AST::Literal) && suffix.value.ascii_only?

        minimum = quantifier.kind == :+ ? 1 : quantifier.minimum
        maximum = quantifier.kind == :bounded ? quantifier.maximum : nil
        PossessiveLiteralSpec.new(quantifier.expression.value, minimum, maximum, suffix.value).freeze
      end

      def constrained_match?(prepared)
        prepared.anchored_start || prepared.anchored_end || prepared.before_final_newline || prepared.line_anchor_start ||
          prepared.line_anchor_end || prepared.positive_prefix || prepared.positive_suffix ||
          prepared.negative_prefix ||
          prepared.negative_suffix || prepared.word_boundary_start || prepared.word_boundary_end ||
          prepared.start_match
      end

      def dot_literal_spec(ast)
        return unless ast.is_a?(AST::Sequence) && ast.parts.length == 3

        prefix, wildcard, suffix = ast.parts
        return unless prefix.is_a?(AST::Literal) && prefix.value.bytesize == 1
        return unless wildcard.is_a?(AST::Any)
        return unless suffix.is_a?(AST::Literal) && suffix.value.bytesize == 1
        return unless prefix.value.ascii_only? && suffix.value.ascii_only?

        DotLiteralSpec.new(prefix.value, suffix.value, multiline?).freeze
      end

      def star_literal_spec(ast)
        return unless ast.is_a?(AST::Sequence) && ast.parts.length == 3

        prefix, quantifier, suffix = ast.parts
        return unless prefix.is_a?(AST::Literal) && prefix.value.bytesize == 1
        return unless quantifier.is_a?(AST::Quantifier) && quantifier.kind == :* && quantifier.mode == :greedy
        return unless quantifier.expression.is_a?(AST::Any)
        return unless suffix.is_a?(AST::Literal) && suffix.value.bytesize == 1
        return unless prefix.value.ascii_only? && suffix.value.ascii_only?

        StarLiteralSpec.new(prefix.value, suffix.value, multiline?).freeze
      end

      def bounded_literal_spec(ast)
        return if ignorecase?

        quantifier = ast.is_a?(AST::Sequence) && ast.parts.one? ? ast.parts.first : ast
        return unless quantifier.is_a?(AST::Quantifier) && quantifier.kind == :bounded
        return unless quantifier.minimum.positive? && quantifier.expression.is_a?(AST::Literal)

        BoundedLiteralSpec.new(quantifier.expression.value * quantifier.minimum,
                               quantifier.expression.value, quantifier.minimum,
                               quantifier.maximum).freeze
      end

      def lazy_star_literal_spec(ast)
        return unless ast.is_a?(AST::Sequence) && ast.parts.length == 3

        prefix, quantifier, suffix = ast.parts
        return unless prefix.is_a?(AST::Literal) && prefix.value.bytesize == 1
        return unless quantifier.is_a?(AST::Quantifier) && quantifier.kind == :* && quantifier.mode == :lazy
        return unless quantifier.expression.is_a?(AST::Any)
        return unless suffix.is_a?(AST::Literal) && suffix.value.bytesize == 1
        return unless prefix.value.ascii_only? && suffix.value.ascii_only?

        LazyStarLiteralSpec.new(prefix.value, suffix.value, multiline?).freeze
      end

      def anchored_class_spec(ast, prepared)
        return if ignorecase?
        return unless prepared.anchored_start && prepared.anchored_end

        quantifier = ast.is_a?(AST::Sequence) && ast.parts.one? ? ast.parts.first : ast
        return unless quantifier.is_a?(AST::Quantifier) && quantifier.kind == :+
        return unless quantifier.expression.is_a?(AST::CharacterClass)

        AnchoredClassSpec.new(ClassPredicates.compiled(quantifier.expression.value).ascii_table).freeze
      end

      def alternation_literal_spec(ast)
        return unless ast.is_a?(AST::Alternation)

        branches = ast.branches.map { |branch| literal_value(branch) }
        return unless branches.length > 1 && branches.all? { |branch| branch&.ascii_only? }

        AlternationLiteralSpec.new(branches.freeze).freeze
      end

      def repeated_alternation_literal_spec(ast)
        return if ignorecase?
        return unless ast.is_a?(AST::Sequence) && ast.parts.length == 2

        repeat, suffix = ast.parts
        return unless repeat.is_a?(AST::Quantifier) && repeat.kind == :+ && repeat.mode == :greedy
        return unless suffix.is_a?(AST::Literal) && suffix.value.ascii_only?

        body = repeat.expression
        body = body.body if body.is_a?(AST::Group)
        return unless body.is_a?(AST::Alternation)

        branches = body.branches.map { |branch| literal_value(branch) }
        return if branches.length < 2 || branches.any?(&:nil?) || branches.any?(&:empty?)
        return unless branches.all?(&:ascii_only?)
        return unless branches.map(&:bytesize).uniq.one?

        RepeatedAlternationLiteralSpec.new(branches.freeze, suffix.value, branches.first.bytesize).freeze
      end

      def class_run_literal_spec(ast)
        return if ignorecase?
        return unless ast.is_a?(AST::Sequence) && ast.parts.length == 3

        prefix, repeat, suffix = ast.parts
        return unless prefix.is_a?(AST::Literal) && prefix.value.ascii_only?
        return unless suffix.is_a?(AST::Literal) && suffix.value.ascii_only?
        return unless repeat.is_a?(AST::Quantifier) && repeat.kind == :bounded
        return unless repeat.minimum == repeat.maximum && repeat.minimum.positive?
        return unless repeat.expression.is_a?(AST::CharacterClass)

        table = ClassPredicates.compiled(repeat.expression.value).ascii_table
        ClassRunLiteralSpec.new(prefix.value, table, repeat.minimum, suffix.value).freeze
      end

      def class_run_chain_spec(ast)
        return if ignorecase?
        return unless ast.is_a?(AST::Sequence) && ast.parts.length == 3

        left, separator, right = ast.parts
        return unless separator.is_a?(AST::Literal) && separator.value.ascii_only?
        return unless class_plus?(left) && class_plus?(right)

        left_table = ClassPredicates.compiled(left.expression.value).ascii_table
        right_table = ClassPredicates.compiled(right.expression.value).ascii_table
        ClassRunChainSpec.new(left_table, separator.value, right_table).freeze
      end

      def class_plus?(node)
        node.is_a?(AST::Quantifier) && node.kind == :+ && node.expression.is_a?(AST::CharacterClass)
      end

      def adjacent_class_run_spec(ast)
        return if ignorecase?
        return unless ast.is_a?(AST::Sequence) && ast.parts.length == 2
        return unless class_plus?(ast.parts[0]) && class_plus?(ast.parts[1])

        left = ast.parts[0].expression
        right = ast.parts[1].expression
        AdjacentClassRunSpec.new(ClassPredicates.compiled(left.value).ascii_table,
                                 ClassPredicates.compiled(right.value).ascii_table).freeze
      end

      def class_run_triple_spec(ast)
        return if ignorecase?
        return unless ast.is_a?(AST::Sequence) && ast.parts.length == 3
        return unless ast.parts.all? { |part| class_run_quantifier?(part) }

        tables = ast.parts.map { |part| class_run_table(part.expression) }
        return if tables.any?(&:nil?)

        ClassRunTripleSpec.new(*tables).freeze
      end

      def literal_class_literal_spec(ast)
        return if ignorecase?
        return unless ast.is_a?(AST::Sequence) && ast.parts.length == 3
        return unless ast.parts[0].is_a?(AST::Literal) && ast.parts[2].is_a?(AST::Literal)
        return unless ast.parts[1].is_a?(AST::Quantifier) && ast.parts[1].kind == :+ &&
                      ast.parts[1].expression.is_a?(AST::CharacterClass)

        LiteralClassLiteralSpec.new(ast.parts[0].value,
                                    ClassPredicates.compiled(ast.parts[1].expression.value).ascii_table,
                                    ast.parts[2].value).freeze
      end

      def ascii_run_spec(ast)
        return if ignorecase?

        quantifier = ast.is_a?(AST::Sequence) && ast.parts.one? ? ast.parts.first : ast
        return unless quantifier.is_a?(AST::Quantifier) && quantifier.kind == :+

        table = class_run_table(quantifier.expression)
        return unless table

        candidates = 256.times.select { |byte| table[byte] }
        character_set = ascii_count_set(candidates)
        AsciiRunSpec.new(table, candidates.one? ? candidates.first.chr(Encoding::ASCII_8BIT) : nil,
                         candidates.freeze,
                         character_set, candidates.length == 256).freeze
      end

      def single_byte_spec(ast)
        table = case ast
                when AST::Any then class_run_table(ast)
                when AST::CharacterClass then ClassPredicates.compiled(ast.value).ascii_table
                end
        return unless table

        candidates = 256.times.select { |byte| table[byte] }
        SingleByteSpec.new(table, candidates.one? ? candidates.first.chr(Encoding::ASCII_8BIT) : nil).freeze
      end

      def ascii_count_set(candidates)
        return if candidates.length > 200
        return if candidates.any? { |byte| [45, 92, 94].include?(byte) }

        candidates.pack("C*").force_encoding(Encoding::ASCII_8BIT).freeze
      end

      def class_run_quantifier?(node)
        node.is_a?(AST::Quantifier) && node.kind == :+ && node.maximum.nil?
      end

      def class_run_table(node)
        case node
        when AST::Any
          256.times.map { |byte| multiline? || byte != 10 }.freeze
        when AST::CharacterClass
          ClassPredicates.compiled(node.value).ascii_table
        when AST::Escape
          256.times.map do |byte|
            CharacterPredicates.escape_matches?(node.kind, byte.chr(Encoding::ASCII_8BIT))
          rescue KeyError
            return nil
          end.freeze
        when AST::Property
          property_ascii_table(node)
        end
      end

      def property_ascii_table(node)
        key = [node.name, node.negated].freeze
        ASCII_PROPERTY_TABLE_MUTEX.synchronize do
          ASCII_PROPERTY_TABLE_CACHE[key] ||= 256.times.map do |byte|
            matched = UnicodeProperties.matches?(node.name, byte.chr(Encoding::ASCII_8BIT))
            node.negated ? !matched : matched
          end.freeze
        end
      end

      def atomic_literal_spec(ast)
        parts = ast.is_a?(AST::Sequence) ? ast.parts : [ast]
        return unless parts.length == 2
        return unless parts.first.is_a?(AST::AtomicGroup) && parts.last.is_a?(AST::Literal)

        body = parts.first.body
        return unless body.is_a?(AST::Alternation)

        branches = body.branches.map { |branch| literal_value(branch) }
        suffix = parts.last.value
        first = branches.first
        return unless first && suffix && first.ascii_only? && suffix.ascii_only? && !suffix.empty?

        subsumed = first + suffix if branches.all? { |branch| atomic_branch_subsumed?(branch, first, suffix) }
        candidates = branches.map { |branch| branch.byteslice(0, 1) }.uniq.freeze
        AtomicLiteralSpec.new(branches.freeze, suffix, subsumed, candidates)
      end

      def atomic_branch_subsumed?(branch, first, suffix)
        return false unless branch&.start_with?(first)

        remainder = branch.delete_prefix(first)
        return true if remainder.empty?
        return false unless (remainder.bytesize % suffix.bytesize).zero?

        suffix * (remainder.bytesize / suffix.bytesize) == remainder
      end
    end

    # Executes the match-only numbered-backreference specialization.
    module BackrefRuntime
      private

      def backref_match?(input, position)
        return !backref_match_result(input, position).nil? if @backref_literal

        position = normalize_position(input, position)
        return false if position.negative? || position > input.bytesize
        return false unless @backref_predicate

        return !variable_backref_match_result(input, position).nil? if @backref_separator.nil?

        separator_position = input.index(@backref_separator, position)
        while separator_position
          run_start = backref_run_start(input, separator_position, @backref_predicate)
          length = separator_position - run_start
          repeated = separator_position + @backref_separator_length
          while length.positive?
            candidate = separator_position - length
            return true if backref_candidate_match?(input, candidate, repeated, length)

            length -= 1
          end
          separator_position = input.index(@backref_separator,
                                           separator_position + @backref_separator_length)
        end
        false
      end

      def backref_match_result(input, position)
        position = normalize_position(input, position)
        return unless position >= 0 && position <= input.bytesize

        if @backref_literal && @backref_separator.nil?
          width = @backref_literal.bytesize
          offset = input.index(@backref_literal + @backref_literal, position)
          return [offset, offset + width * 2, [[offset, offset + width]]] if offset

          return
        end

        if @backref_literal
          width = @backref_literal.bytesize
          separator_position = input.index(@backref_separator, position)
          while separator_position
            candidate = separator_position - width
            repeated = separator_position + @backref_separator.bytesize
            if candidate >= position && input.byteslice(candidate, width) == @backref_literal &&
               input.byteslice(repeated, width) == @backref_literal
              return [candidate, repeated + width, [[candidate, separator_position]]]
            end

            separator_position = input.index(@backref_separator,
                                             separator_position + @backref_separator.bytesize)
          end
          return
        end

        return unless @backref_predicate

        return variable_backref_match_result(input, position) if @backref_separator.nil?

        separator_position = input.index(@backref_separator, position)
        while separator_position
          run_start = backref_run_start(input, separator_position, @backref_predicate)
          length = separator_position - run_start
          repeated = separator_position + @backref_separator_length
          while length.positive?
            candidate = separator_position - length
            return [candidate, repeated + length, [[candidate, separator_position]]] if backref_candidate_match?(input, candidate, repeated, length)

            length -= 1
          end
          separator_position = input.index(@backref_separator,
                                           separator_position + @backref_separator_length)
        end
        nil
      end

      def backref_data(spec, ignorecase: false)
        return [nil, nil, nil] unless spec

        body = spec.body
        body = body.parts.first if body.is_a?(AST::Sequence) && body.parts.one?
        literal = literal_ast_value(body)
        return [nil, spec.separator, literal] if literal

        if body.is_a?(AST::Quantifier) && %i[* +].include?(body.kind) &&
           body.expression.is_a?(AST::Literal) && body.expression.value.bytesize == 1
          table = Array.new(256, false)
          table[body.expression.value.getbyte(0)] = true
          return [table.freeze, spec.separator, nil]
        end
        return [nil, nil, nil] unless body.is_a?(AST::Quantifier) && body.kind == :+ &&
                                      body.expression.is_a?(AST::CharacterClass)

        table = if ignorecase
                  256.times.map do |byte|
                    character = byte.chr(Encoding::ASCII_8BIT)
                    ClassPredicates.matches?(body.expression.value, character.downcase)
                  end.freeze
                else
                  ClassPredicates.compiled(body.expression.value).ascii_table
                end
        [table, spec.separator, nil]
      end

      def literal_ast_value(node)
        return node.value if node.is_a?(AST::Literal)
        return unless node.is_a?(AST::Sequence)

        values = node.parts.map { |part| literal_ast_value(part) }
        values.all? ? values.join : nil
      end

      def backref_run_start(input, separator_position, predicate)
        run_start = separator_position
        run_start -= 1 while run_start.positive? &&
                             predicate[input.getbyte(run_start - 1)]
        run_start
      end

      def backref_candidate_match?(input, candidate, repeated, length)
        captured = input.byteslice(candidate, length)
        repeated_value = input.byteslice(repeated, length)
        @backref_ignorecase ? captured.casecmp?(repeated_value) : captured == repeated_value
      end

      def variable_backref_match_result(input, position)
        run_end = position
        run_end += 1 while run_end < input.bytesize && @backref_predicate[input.getbyte(run_end)]
        length = (run_end - position) / 2
        return [position, position, [[position, position]]] if length.zero? && @backref_empty_allowed
        return unless length.positive?

        repeated = position + length
        captured = input.byteslice(position, length)
        repeated_value = input.byteslice(repeated, length)
        return unless @backref_ignorecase ? captured.casecmp?(repeated_value) : captured == repeated_value

        [position, repeated + length, [[position, repeated]]]
      end
    end

    # Executes the linear UTF-8 class/property run specialization.
    module UnicodeRuntime
      private

      def unicode_match?(input, position = 0)
        spec = @unicode_spec
        return true if spec.minimum.zero? && position <= input.bytesize
        return unicode_letter_match?(input) if spec.kind == :property && @unicode_matcher == :letter? &&
                                               !@unicode_negated && spec.minimum == 1 && position.zero?
        return unicode_word_match?(input) if spec.kind == :class && @unicode_matcher == :word? &&
                                             spec.minimum == 1 && position.zero?
        return unicode_range_match?(input) if spec.kind == :class && @unicode_range &&
                                              !@unicode_negated && spec.minimum == 1 && position.zero?
        return !unicode_match_result(input, position).nil? if position.positive?

        count = 0
        input.each_codepoint do |codepoint|
          if unicode_character_matches?(spec, codepoint)
            count += 1
            return true if count >= spec.minimum
          else
            count = 0
          end
        end
        spec.minimum.zero?
      end

      def unicode_letter_match?(input)
        input.each_codepoint do |codepoint|
          fast = fast_unicode_letter?(codepoint)
          return true if fast || (fast.nil? && UnicodeProperties.letter?(codepoint.chr(Encoding::UTF_8)))
        end
        false
      end

      def unicode_word_match?(input)
        input.each_codepoint do |codepoint|
          return true if unicode_word_codepoint?(codepoint)
        end
        false
      end

      def unicode_word_codepoint?(codepoint)
        return true if codepoint == 95 || codepoint.between?(48, 57) ||
                       codepoint.between?(65, 90) || codepoint.between?(97, 122)

        fast = fast_unicode_letter?(codepoint)
        return true if fast
        return false if fast == false

        UnicodeProperties.word?(codepoint.chr(Encoding::UTF_8))
      end

      def unicode_range_match?(input)
        minimum, maximum = @unicode_range
        input.each_codepoint do |codepoint|
          return true if codepoint.between?(minimum, maximum)
        end
        false
      end

      def unicode_match_result(input, position)
        spec = @unicode_spec
        return unless spec

        position = unicode_byte_position(input, position)

        cursor = 0
        run_start = nil
        count = 0
        input.each_char do |character|
          character_start = cursor
          cursor += character.bytesize
          next if character_start < position

          if unicode_character_matches?(spec, character.ord)
            run_start ||= character_start
            count += 1
            next
          end

          return [run_start, character_start, []] if run_start && count >= spec.minimum

          run_start = nil
          count = 0
        end

        return [run_start, cursor, []] if run_start && count >= spec.minimum

        nil
      end

      def unicode_byte_position(input, character_position)
        return 0 if character_position <= 0

        byte_position = 0
        index = 0
        input.each_char do |character|
          break if index >= character_position

          byte_position += character.bytesize
          index += 1
        end
        byte_position
      end

      def unicode_character_position(input, byte_position)
        return 0 if byte_position <= 0

        character_position = 0
        cursor = 0
        input.each_char do |character|
          break if cursor >= byte_position

          cursor += character.bytesize
          character_position += 1
        end
        character_position
      end

      def unicode_character_matches?(spec, character)
        codepoint = CharacterPredicates.codepoint(character)
        return codepoint.between?(*@unicode_range) ^ @unicode_negated if @unicode_range
        return unicode_property_fast_match(codepoint) ^ @unicode_negated if @unicode_matcher
        return @unicode_class_predicate.matches?(character.chr(Encoding::UTF_8)) if spec.kind == :class

        fast = unicode_property_fast_match(codepoint)
        return fast ^ @unicode_negated unless fast.nil?

        value = @unicode_predicate.call(character.chr(Encoding::UTF_8))
        @unicode_negated ? !value : value
      end

      def unicode_property_fast_match(character)
        codepoint = CharacterPredicates.codepoint(character)
        case @unicode_matcher
        when :letter?
          fast_unicode_letter?(codepoint)
        when :word?
          return true if codepoint == 95 || codepoint.between?(48, 57) ||
                         codepoint.between?(65, 90) || codepoint.between?(97, 122)

          fast_unicode_letter?(codepoint)
        end
      end

      def fast_unicode_letter?(codepoint)
        return true if codepoint.between?(65, 90) || codepoint.between?(97, 122)
        return false if codepoint < 128
        return true if codepoint.between?(0x3040, 0x30ff) ||
                       codepoint.between?(0x3400, 0x4dbf) ||
                       codepoint.between?(0x4e00, 0x9fff) ||
                       codepoint.between?(0xac00, 0xd7af)

        nil
      end

      def initialize_unicode_runtime(spec)
        return unless spec

        if spec.kind == :class
          if spec.value == "[:word:]"
            @unicode_matcher = :word?
            @unicode_negated = false
            return
          end
          @unicode_class_predicate = ClassPredicates.compiled(spec.value)
          @unicode_range = simple_unicode_range(spec.value)
          @unicode_negated = false
          return
        end

        name, @unicode_negated = spec.value
        normalized = name.sub("Is", "").sub("^", "")
        @unicode_matcher = UnicodeProperties::PROPERTY_MATCHERS.fetch(normalized)
        @unicode_predicate = UnicodeProperties.method(@unicode_matcher)
        @unicode_range = unicode_property_range(@unicode_matcher)
      end

      def simple_unicode_range(source)
        characters = source.each_char.to_a
        return unless characters.length == 3 && characters[1] == "-"

        [characters[0].ord, characters[2].ord]
      end

      def unicode_property_range(matcher)
        {
          ascii?: [0, 127],
          hiragana?: [0x3040, 0x309f],
          katakana?: [0x30a0, 0x30ff],
          han?: [0x4e00, 0x9fff],
          greek?: [0x370, 0x3ff],
          cyrillic?: [0x400, 0x4ff],
          arabic?: [0x600, 0x6ff]
        }[matcher]
      end
    end

    # Handles edge assertions around candidate matches.
    module GuardedRuntime
      private

      def search_guarded(input, position)
        if @exact_literal && (@positive_prefix || @positive_suffix || @negative_suffix ||
                               @negative_prefix || @word_boundary_start || @word_boundary_end)
          return search_guarded_literal(input, position)
        end
        return search_guarded_prefix(input, position) if @prefix_literal

        candidate = position
        while candidate < input.bytesize
          return true if guarded_candidate?(input, candidate)

          candidate += 1
        end
        false
      end

      def search_guarded_literal(input, position)
        candidate = input.index(@exact_literal, position)
        while candidate
          end_position = candidate + @exact_literal.bytesize
          positive_prefix = positive_prefix_at?(input, candidate)
          positive_suffix = !@positive_suffix || literal_bytes_at?(input, end_position, @positive_suffix)
          prefix_blocked = @negative_prefix && candidate >= @negative_prefix.bytesize &&
                           literal_bytes_at?(input, candidate - @negative_prefix.bytesize, @negative_prefix)
          suffix_blocked = negative_suffix_at?(input, end_position)
          start_boundary = !@word_boundary_start || boundary_at?(input, candidate, @word_boundary_start)
          end_boundary = !@word_boundary_end || boundary_at?(input, end_position, @word_boundary_end)
          return true if positive_prefix && positive_suffix && !prefix_blocked && !suffix_blocked &&
                         start_boundary && end_boundary

          candidate = input.index(@exact_literal, candidate + 1)
        end
        false
      end

      def guarded_literal_match_result(input, position)
        candidate = input.index(@exact_literal, position)
        while candidate
          finish = candidate + @exact_literal.bytesize
          prefix_blocked = @negative_prefix && candidate >= @negative_prefix.bytesize &&
                           literal_bytes_at?(input, candidate - @negative_prefix.bytesize, @negative_prefix)
          return [candidate, finish, []] if positive_prefix_at?(input, candidate) && !prefix_blocked &&
                                            positive_suffix_at?(input, finish) &&
                                            !negative_suffix_at?(input, finish)

          candidate = input.index(@exact_literal, candidate + 1)
        end
        nil
      end

      def search_guarded_prefix(input, position)
        candidate = input.index(@prefix_literal, position)
        while candidate
          return true if guarded_candidate?(input, candidate)

          candidate = input.index(@prefix_literal, candidate + 1)
        end
        false
      end

      def guarded_candidate?(input, candidate)
        return false unless positive_prefix_at?(input, candidate)
        return false if @word_boundary_start && !boundary_at?(input, candidate, @word_boundary_start)
        return false if @negative_prefix && candidate >= @negative_prefix.bytesize &&
                        literal_bytes_at?(input, candidate - @negative_prefix.bytesize, @negative_prefix)

        active = 0
        cursor = candidate
        while cursor < input.bytesize
          active = transition(active, input.getbyte(cursor), cursor == candidate)
          accepted = (active & @accept_mask) != 0
          return true if accepted && positive_suffix_at?(input, cursor + 1) &&
                         !negative_suffix_at?(input, cursor + 1) &&
                         (!@word_boundary_end || boundary_at?(input, cursor + 1, @word_boundary_end))
          break if active.zero?

          cursor += 1
        end
        false
      end

      def negative_suffix_at?(input, position)
        @negative_suffix && literal_bytes_at?(input, position, @negative_suffix)
      end

      def positive_suffix_at?(input, position)
        !@positive_suffix || literal_bytes_at?(input, position, @positive_suffix)
      end

      def positive_prefix_at?(input, position)
        return true unless @positive_prefix
        return false if position < @positive_prefix.bytesize

        literal_bytes_at?(input, position - @positive_prefix.bytesize, @positive_prefix)
      end

      def guarded_search?
        @positive_prefix || @positive_suffix || @negative_prefix || @negative_suffix ||
          @word_boundary_start || @word_boundary_end
      end

      def word_boundary_at?(input, position)
        before = position.positive? && word_byte?(input.getbyte(position - 1))
        after = position < input.bytesize && word_byte?(input.getbyte(position))
        before != after
      end

      def boundary_at?(input, position, boundary)
        result = word_boundary_at?(input, position)
        boundary == :not_word_boundary ? !result : result
      end

      def word_byte?(byte)
        return false unless byte

        @word_table ? @word_table[byte] : CharacterPredicates.word?(byte.chr)
      end
    end

    # Executes a single-byte repeated literal followed by a literal suffix.
    module RepeatLiteralRuntime
      private

      def repeat_literal_match?(input, position)
        spec = @repeat_literal_spec
        return false unless spec

        position = normalize_position(input, position)
        return false if position.negative? || position > input.bytesize

        suffix_position = input.index(spec.suffix, position + 1)
        while suffix_position
          cursor = suffix_position
          cursor -= 1 while cursor > position && input.getbyte(cursor - 1) == spec.byte
          return true if cursor < suffix_position

          suffix_position = input.index(spec.suffix, suffix_position + 1)
        end
        false
      end
    end

    module PossessiveLiteralRuntime
      private

      def possessive_literal_match?(input, position)
        spec = @possessive_literal_spec
        return false unless spec

        position = normalize_position(input, position)
        return false if position.negative? || position > input.bytesize

        return possessive_unbounded_suffix_match?(input, position, spec) if spec.maximum.nil?

        candidate = input.index(spec.unit, position)
        while candidate
          finish = possessive_literal_finish(input, candidate, spec)
          return true if finish && input.byteslice(finish, spec.suffix.bytesize) == spec.suffix

          candidate = input.index(spec.unit, candidate + 1)
        end
        false
      end

      def possessive_literal_match_result(input, position)
        spec = @possessive_literal_spec
        return unless spec

        return possessive_unbounded_suffix_match_result(input, position, spec) if spec.maximum.nil?

        candidate = input.index(spec.unit, position)
        while candidate
          finish = possessive_literal_finish(input, candidate, spec)
          return [candidate, finish + spec.suffix.bytesize, []] if finish &&
                                                                   input.byteslice(finish,
                                                                                   spec.suffix.bytesize) == spec.suffix

          candidate = input.index(spec.unit, candidate + 1)
        end
        nil
      end

      def possessive_unbounded_suffix_match_result(input, position, spec)
        suffix_position = input.index(spec.suffix, position + spec.unit.bytesize)
        while suffix_position
          cursor = suffix_position
          count = 0
          while cursor >= spec.unit.bytesize &&
                input.byteslice(cursor - spec.unit.bytesize, spec.unit.bytesize) == spec.unit
            cursor -= spec.unit.bytesize
            count += 1
          end
          return [cursor, suffix_position + spec.suffix.bytesize, []] if count >= spec.minimum

          suffix_position = input.index(spec.suffix, suffix_position + 1)
        end
        nil
      end

      def possessive_unbounded_suffix_match?(input, position, spec)
        suffix_position = input.index(spec.suffix, position + spec.unit.bytesize)
        while suffix_position
          return true if suffix_position >= spec.unit.bytesize &&
                         input.byteslice(suffix_position - spec.unit.bytesize, spec.unit.bytesize) == spec.unit

          suffix_position = input.index(spec.suffix, suffix_position + 1)
        end
        false
      end

      def possessive_literal_finish(input, candidate, spec)
        finish = candidate
        count = 0
        while (spec.maximum.nil? || count < spec.maximum) &&
              input.byteslice(finish, spec.unit.bytesize) == spec.unit
          finish += spec.unit.bytesize
          count += 1
        end
        count >= spec.minimum ? finish : nil
      end
    end

    # Executes a literal-any-literal candidate search with option-aware dot.
    module DotLiteralRuntime
      private

      def dot_literal_match?(input, position)
        spec = @dot_literal_spec
        return false unless spec

        position = normalize_position(input, position)
        return false if position.negative? || position > input.bytesize

        candidate = input.index(spec.prefix, position)
        while candidate
          middle = candidate + 1
          suffix_position = candidate + 2
          if suffix_position < input.bytesize &&
             (spec.allow_newline || input.getbyte(middle) != 10) &&
             input.getbyte(suffix_position) == spec.suffix.getbyte(0)
            return true
          end

          candidate = input.index(spec.prefix, candidate + 1)
        end
        false
      end
    end

    # Executes a literal-any-star-literal candidate search with dot semantics.
    module StarLiteralRuntime
      private

      def star_literal_match?(input, position)
        spec = @star_literal_spec
        return false unless spec

        position = normalize_position(input, position)
        return false if position.negative? || position > input.bytesize

        candidate = input.index(spec.prefix, position)
        while candidate
          suffix_position = input.index(spec.suffix, candidate + 1)
          while suffix_position
            newline = input.index("\n", candidate + 1)
            return true if spec.allow_newline || newline.nil? || newline >= suffix_position

            suffix_position = input.index(spec.suffix, suffix_position + 1)
          end
          candidate = input.index(spec.prefix, candidate + 1)
        end
        false
      end
    end

    # Executes a bounded literal quantifier as a fixed minimum-run search.
    module BoundedLiteralRuntime
      private

      def bounded_literal_match?(input, position)
        spec = @bounded_literal_spec
        return false unless spec

        position = normalize_position(input, position)
        return false if position.negative? || position > input.bytesize

        !input.index(spec.literal, position).nil?
      end
    end

    # Executes a lazy literal-any-star-literal candidate search.
    module LazyStarLiteralRuntime
      private

      def lazy_star_literal_match?(input, position)
        spec = @lazy_star_literal_spec
        return false unless spec

        position = normalize_position(input, position)
        return false if position.negative? || position > input.bytesize

        candidate = input.index(spec.prefix, position)
        while candidate
          suffix_position = input.index(spec.suffix, candidate + 1)
          return true if suffix_position && lazy_dot_range_valid?(input, candidate + 1, suffix_position, spec)

          candidate = input.index(spec.prefix, candidate + 1)
        end
        false
      end

      def lazy_dot_range_valid?(input, start_position, finish, spec)
        return true if spec.allow_newline

        input.index("\n", start_position).nil? || input.index("\n", start_position) >= finish
      end
    end

    # Executes an anchored positive character-class run over the whole input.
    module AnchoredClassRuntime
      private

      def anchored_class_match?(input, position)
        spec = @anchored_class_spec
        return false unless spec && position.zero?

        input.each_byte.all? { |byte| spec.table[byte] }
      end
    end

    # Executes an alternation of independent ASCII literals.
    module AlternationLiteralRuntime
      private

      def alternation_literal_match?(input, position)
        spec = @alternation_literal_spec
        return false unless spec

        position = normalize_position(input, position)
        return false if position.negative? || position > input.bytesize

        spec.branches.any? { |branch| input.index(branch, position) }
      end
    end

    # Finds a suffix preceded by one complete fixed-width alternation branch.
    # One branch is sufficient because the repeated expression has a `+`
    # minimum; additional branches are accepted by the same local condition.
    module RepeatedAlternationLiteralRuntime
      private

      def repeated_alternation_literal_match?(input, position)
        spec = @repeated_alternation_literal_spec
        return false unless spec

        position = normalize_position(input, position)
        return false if position.negative? || position > input.bytesize

        suffix_position = input.index(spec.suffix, position + spec.width)
        while suffix_position
          branch_start = suffix_position - spec.width
          if branch_start >= position &&
             spec.branches.any? { |branch| literal_bytes_at?(input, branch_start, branch) }
            return true
          end

          suffix_position = input.index(spec.suffix, suffix_position + 1)
        end
        false
      end

      def literal_bytes_at?(input, position, literal)
        return false if position.negative? || position + literal.bytesize > input.bytesize

        index = 0
        while index < literal.bytesize
          return false unless input.getbyte(position + index) == literal.getbyte(index)

          index += 1
        end
        true
      end
    end

    # Checks an exact fixed-width character-class run backwards from a suffix.
    module ClassRunLiteralRuntime
      private

      def class_run_literal_match?(input, position)
        spec = @class_run_literal_spec
        return false unless spec

        static_dfa_data if @dfa_enabled && @static_dfa_data.nil?

        position = normalize_position(input, position)
        return false if position.negative? || position > input.bytesize

        suffix_position = input.index(spec.suffix, position + spec.prefix.bytesize + spec.minimum)
        while suffix_position
          run_start = suffix_position - spec.minimum
          prefix_start = run_start - spec.prefix.bytesize
          if prefix_start >= position &&
             literal_bytes_at?(input, prefix_start, spec.prefix) &&
             class_run_bytes_match?(input, run_start, suffix_position, spec.table)
            return true
          end

          suffix_position = input.index(spec.suffix, suffix_position + 1)
        end
        false
      end

      def class_run_bytes_match?(input, start, finish, table)
        cursor = start
        while cursor < finish
          return false unless table[input.getbyte(cursor)]

          cursor += 1
        end
        true
      end
    end

    # Checks two non-empty ASCII class runs around a literal separator.
    module ClassRunChainRuntime
      private

      def class_run_chain_match?(input, position)
        spec = @class_run_chain_spec
        return false unless spec

        position = normalize_position(input, position)
        return false if position.negative? || position > input.bytesize

        separator_position = input.index(spec.separator, position)
        while separator_position
          left = separator_position
          left -= 1 while left > position && spec.left_table[input.getbyte(left - 1)]
          right = separator_position + spec.separator.bytesize
          right += 1 while right < input.bytesize && spec.right_table[input.getbyte(right)]
          return true if left < separator_position && right > separator_position + spec.separator.bytesize

          separator_position = input.index(spec.separator, separator_position + 1)
        end
        false
      end
    end

    # Finds a non-empty left class run immediately followed by a right run.
    module AdjacentClassRunRuntime
      private

      def adjacent_class_run_match?(input, position)
        spec = @adjacent_class_run_spec
        return false unless spec

        position = normalize_position(input, position)
        return false if position.negative? || position > input.bytesize

        cursor = position
        while cursor < input.bytesize
          if spec.right_table[input.getbyte(cursor)] && cursor > position &&
             spec.left_table[input.getbyte(cursor - 1)]
            return true
          end

          cursor += 1
        end
        false
      end
    end

    # Finds three non-empty runs by walking the middle run backwards from the
    # last-run boundary.
    module ClassRunTripleRuntime
      private

      def class_run_triple_match?(input, position)
        spec = @class_run_triple_spec
        return false unless spec

        position = normalize_position(input, position)
        return false if position.negative? || position > input.bytesize

        cursor = position
        while cursor < input.bytesize
          if spec.last_table[input.getbyte(cursor)] && cursor > position &&
             spec.middle_table[input.getbyte(cursor - 1)]
            middle_start = cursor - 1
            middle_start -= 1 while middle_start > position && spec.middle_table[input.getbyte(middle_start - 1)]
            return true if middle_start < cursor && middle_start > position &&
                           spec.first_table[input.getbyte(middle_start - 1)]
          end

          cursor += 1
        end
        false
      end
    end

    # Searches a literal prefix, a non-empty class run, and a literal suffix.
    module LiteralClassLiteralRuntime
      private

      def literal_class_literal_match?(input, position)
        spec = @literal_class_literal_spec
        return false unless spec

        position = normalize_position(input, position)
        return false if position.negative? || position > input.bytesize

        candidate = input.index(spec.prefix, position)
        while candidate
          run_start = candidate + spec.prefix.bytesize
          suffix_position = input.index(spec.suffix, run_start + 1)
          while suffix_position
            return true if class_run_bytes_match?(input, run_start, suffix_position, spec.table)

            suffix_position = input.index(spec.suffix, suffix_position + 1)
          end

          candidate = input.index(spec.prefix, candidate + 1)
        end
        false
      end
    end

    # Scans any non-empty ASCII class/escape run with its compiled byte table.
    module AsciiRunRuntime
      private

      def ascii_run_match?(input, position)
        spec = @ascii_run_spec
        return false unless spec

        position = normalize_position(input, position)
        return false if position.negative? || position > input.bytesize
        return position < input.bytesize if spec.any_byte
        return !input.index(spec.candidate_byte, position).nil? if spec.candidate_byte
        return input.count(spec.character_set).positive? if position.zero? && spec.character_set

        cursor = position
        while cursor < input.bytesize
          return true if spec.table[input.getbyte(cursor)]

          cursor += 1
        end
        false
      end
    end

    # Preserves ordered branch commitment for simple atomic literal groups.
    module AtomicLiteralRuntime
      private

      def atomic_literal_match?(input, position)
        spec = @atomic_literal_spec
        return false unless spec

        position = normalize_position(input, position)
        return false if position.negative? || position > input.bytesize
        return !input.index(spec.subsumed_literal, position).nil? if spec.subsumed_literal

        candidate = atomic_literal_candidate(input, position, spec.candidate_bytes)
        while candidate
          branch = spec.branches.find do |value|
            literal_bytes_at?(input, candidate, value)
          end
          if branch
            suffix_position = candidate + branch.bytesize
            return true if literal_bytes_at?(input, suffix_position, spec.suffix)
          end
          candidate = atomic_literal_candidate(input, candidate + 1, spec.candidate_bytes)
        end
        false
      end

      def atomic_literal_candidate(input, position, first_bytes)
        candidate = nil
        first_bytes.each do |byte|
          found = input.index(byte, position)
          candidate = found if found && (candidate.nil? || found < candidate)
        end
        candidate
      end
    end
  end
end
