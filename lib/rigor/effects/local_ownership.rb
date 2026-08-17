# frozen_string_literal: true

require "prism"

require_relative "../source/node_children"

module Rigor
  module Effects
    # Which of a method body's locals the frame **owns** — freshly allocated here and never let out
    # (ADR-103 WD4; the proof obligations are `control-flow-analysis.md` § Proof obligations).
    #
    # Ruby has no by-ref parameters, so `mutate.local` cannot mean "a write into an out-parameter" as it
    # does in PHP. It means the mutated receiver is invisible to the caller, and that is an ownership
    # question: a local whose every assignment allocates (`[]`, `{}`, `""`, `.new`, `.dup`) and which never
    # escapes the body is one no caller can observe being mutated.
    #
    # The analysis is deliberately **flow-insensitive and whole-body**: a local that escapes anywhere
    # disqualifies, even if the escape happens after the mutation. That is strictly more conservative than
    # the "escaped before the mutating call" reading, which is the direction false positives are budgeted
    # in ([ADR-5](../adr/5-robustness-principle.md)) — an unproven local mutation becomes an
    # `unknown-ownership` taint, never a proven `mutate` label.
    #
    # This is the tracer slice's approximation, not the eventual answer. `ClosureEscapeAnalyzer` answers a
    # different question (fact retention, not "does the code contain") and is deliberately left alone.
    module LocalOwnership
      # Assignment right-hand sides that witness a fresh allocation. `.new` and `.dup` / `.clone` follow
      # [ADR-76](../adr/76-effect-modeling-freeze-dup-shape-preservation.md)'s reading of `dup` as the
      # allocation witness.
      ALLOCATING_SELECTORS = %i[new dup clone].to_set.freeze

      module_function

      # The set of frame-owned local names in `body`, given the method's parameter names (a parameter is
      # never frame-owned — the caller holds the same object, so mutating it is `mutate.instance`).
      def owned(body, parameter_names)
        return Set.new if body.nil?

        assignments = {}
        escaped = Set.new
        collect(body, assignments, escaped)
        escaped.merge(trailing_reads(body))
        assignments.filter_map do |name, values|
          next if escaped.include?(name) || parameter_names.include?(name)

          name if values.all? { |value| allocation?(value) }
        end.to_set
      end

      # Whether `node` is an expression that allocates a fresh object this frame is the sole holder of.
      def allocation?(node)
        case node
        when Prism::ArrayNode, Prism::HashNode, Prism::StringNode, Prism::InterpolatedStringNode,
             Prism::LambdaNode
          true
        when Prism::CallNode
          ALLOCATING_SELECTORS.include?(node.name) || unary_plus_string?(node)
        else
          false
        end
      end

      # `+""` — the frozen-string-literal era's spelling of "a fresh mutable String".
      def unary_plus_string?(node)
        node.name == :+@ && node.receiver.is_a?(Prism::StringNode)
      end

      def collect(node, assignments, escaped)
        return unless node.is_a?(Prism::Node)

        record_assignment(node, assignments, escaped)
        record_escapes(node, escaped)
        node.rigor_each_child { |child| collect(child, assignments, escaped) }
      end

      def record_assignment(node, assignments, escaped)
        case node
        when Prism::LocalVariableWriteNode
          (assignments[node.name.to_s] ||= []) << node.value
          # `y = x` hands the same object to a second name; neither can be proven frame-private cheaply.
          escaped << node.value.name.to_s if node.value.is_a?(Prism::LocalVariableReadNode)
        when Prism::LocalVariableOperatorWriteNode, Prism::LocalVariableOrWriteNode,
             Prism::LocalVariableAndWriteNode, Prism::LocalVariableTargetNode
          # Not an allocation, and a multi-assign target's value is not statically one either: record a
          # nil right-hand side so the all-allocations test fails.
          (assignments[node.name.to_s] ||= []) << nil
        end
      end

      # An escape is any position from which a caller could later reach the object: a call argument (the
      # callee may store it), the right-hand side of a write to state that outlives the frame, an element
      # of a constructed collection, or an explicit `return`.
      def record_escapes(node, escaped)
        case node
        when Prism::CallNode
          node.arguments&.arguments&.each { |argument| note_read(argument, escaped) }
          note_read(node.block.expression, escaped) if node.block.is_a?(Prism::BlockArgumentNode)
        when Prism::ReturnNode
          node.arguments&.arguments&.each { |argument| note_read(argument, escaped) }
        when Prism::ArrayNode
          node.elements.each { |element| note_read(element, escaped) }
        else
          note_read(stored_value(node), escaped)
        end
      end

      # The value half of a write into state that outlives the frame, or of a hash entry. nil for every
      # other node, which {note_read} ignores.
      def stored_value(node)
        case node
        when Prism::AssocNode, Prism::InstanceVariableWriteNode, Prism::ClassVariableWriteNode,
             Prism::GlobalVariableWriteNode, Prism::ConstantWriteNode
          node.value
        end
      end

      def note_read(node, escaped)
        escaped << node.name.to_s if node.is_a?(Prism::LocalVariableReadNode)
      end

      # A body whose value is a bare local read hands that local to the caller. Only the tail matters —
      # every other position is covered by {record_escapes}.
      def trailing_reads(body)
        statements = body.is_a?(Prism::StatementsNode) ? body.body : [body]
        last = statements.last
        last.is_a?(Prism::LocalVariableReadNode) ? [last.name.to_s] : []
      end

      private_class_method :collect, :record_assignment, :record_escapes, :stored_value, :note_read,
                           :trailing_reads
    end
  end
end
