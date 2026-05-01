# frozen_string_literal: true

require_relative "../source/node_walker"
require_relative "../scope"
require_relative "fallback_tracer"
require_relative "scope_indexer"

module Rigor
  module Inference
    # Walks an AST and reports per-node-class coverage of `Rigor::Scope#type_of`.
    #
    # For every visited node the scanner runs `type_of` with a fresh
    # `FallbackTracer` and inspects the first recorded event:
    #
    # * If the first event's `node_class` matches the visited node's class,
    #   the engine entered the fallback (else) branch *for this very node* —
    #   the node is counted as **directly unrecognized**.
    # * Otherwise the typer either succeeded outright or recursed into a child
    #   that itself was unrecognized; the visited node is counted as
    #   recognized so pass-through wrappers (`ProgramNode`, `StatementsNode`,
    #   `ParenthesesNode`, ...) are not double-counted along with their leaves.
    #
    # This class is intended for tooling probes and CI gates rather than the
    # hot inference path: it allocates a tracer per visited node and discards
    # the inferred type values.
    class CoverageScanner
      Result = Data.define(:visits, :unrecognized, :events) do
        # @return [Integer] sum of all visits across node classes.
        def visited_count
          visits.values.sum
        end

        # @return [Integer] sum of directly-unrecognized counts across classes.
        def unrecognized_count
          unrecognized.values.sum
        end

        # @return [Float] unrecognized_count / visited_count, or 0.0 when empty.
        def unrecognized_ratio
          total = visited_count
          return 0.0 if total.zero?

          unrecognized_count.fdiv(total)
        end
      end

      # @param scope [Rigor::Scope] base scope used for every type_of call. Defaults to `Scope.empty`.
      def initialize(scope: nil)
        @scope = scope || Scope.empty
      end

      # @param root [Prism::Node]
      # @return [Result]
      def scan(root)
        visits = Hash.new(0)
        unrecognized = Hash.new(0)
        events = []

        # Build the per-node scope index once per scan so locals bound
        # earlier in the program flow into the scope used to type every
        # later node. The indexer walks the program with a tracer-less
        # StatementEvaluator and propagates the recorded scope down to
        # expression-interior nodes the evaluator does not visit. The
        # second pass below re-types each node with its own tracer so
        # the per-class fallback statistics stay attributable.
        scope_index = ScopeIndexer.index(root, default_scope: @scope)

        Source::NodeWalker.each(root) do |node|
          visits[node.class] += 1

          tracer = FallbackTracer.new
          scope_index[node].type_of(node, tracer: tracer)

          first_event = tracer.events.first
          next unless first_event && first_event.node_class == node.class

          unrecognized[node.class] += 1
          events << first_event
        end

        Result.new(visits: visits, unrecognized: unrecognized, events: events)
      end
    end
  end
end
