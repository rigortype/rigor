# frozen_string_literal: true

module Rigor
  module Analysis
    # ADR-24 slice 4a — records every *implicit-self* method call the inference engine could not resolve to any
    # method (RBS tier miss + user-class ancestor-walk miss + not a `Dynamic` receiver), captured at the single
    # engine choke-point where such a call falls through to `Dynamic[top]` (`ExpressionTyper#call_type_for` →
    # `fallback_for`).
    #
    # ## Why a recorder, not a check-rule
    #
    # Slice 4 attempt 1 reimplemented self-call resolution inside `CheckRules` and produced 135 false
    # positives on Rigor's own `lib` ([ADR-24](../../../docs/adr/24-self-method-call-resolution.md) § "Slice
    # 4"): the second, weaker resolution path could not see `module_function` siblings, `Data.define` /
    # `Struct` accessors, or mixin-contributed methods that the *engine's* real resolution handles. Recording
    # at the engine's own miss point reuses that real resolution — those methods resolve before the miss, so
    # they never reach the recorder. This module is the ADR-46 / ADR-47 "collect at evaluation time, never
    # recompute" lesson applied to self-calls.
    #
    # ADR-24 slice 4 (`call.self-undefined-method`) consumes the recorded misses behind a confidently-closed-class
    # gate (see `CheckRules` L775). The rule ships `:off` by default — {active?} is false on a normal run, so
    # the instrumented choke-point pays a single integer read and records nothing. Recording is purely
    # observational; it never changes a diagnostic.
    #
    # Modelled on {DependencyRecorder}: process-thread-local accumulator, a cheap disabled fast path, and a
    # frozen snapshot for consumers.
    module SelfCallResolutionRecorder
      KEY = :__rigor_self_call_resolution_recorder__
      private_constant :KEY

      # One unresolved implicit-self call. `class_name` is the receiver's statically known class (the
      # enclosing `self` type); `method_name` the called name; `node` the Prism `CallNode` (held in-memory so
      # the `call.self-undefined-method` collector can resolve its scope from the scope index and apply the
      # closed-class gate); `path` / `line` / `column` locate the call site for the diagnostic.
      UnresolvedSelfCall = Data.define(:class_name, :method_name, :node, :path, :line, :column)

      # Mutable per-consumer accumulator, frozen into a {Record} snapshot when {record_for} returns. Dedupes by
      # the full call tuple so a method body re-typed under several call-site signatures records the miss once.
      class Accumulator
        attr_reader :consumer, :calls

        def initialize(consumer)
          @consumer = consumer
          @calls = []
          @seen = Set.new
        end

        def add(call)
          return unless @seen.add?(call)

          @calls << call
        end

        def snapshot
          Record.new(consumer: consumer, calls: calls.dup.freeze)
        end
      end

      Record = Data.define(:consumer, :calls)

      # Module-level activation count so the disabled fast path ({active?}) is a plain integer read rather
      # than a `Thread.current` hash lookup — the instrumented choke-point is on the dispatch miss path, so a
      # normal (non-recording) run must pay as little as possible.
      @active_count = 0
      @mutex = Mutex.new

      module_function

      # Activates recording for `consumer` (the path being analyzed) for the duration of the block and returns
      # the frozen {Record}. Nests safely; restores the previous recorder on exit.
      def record_for(consumer)
        previous = Thread.current[KEY]
        accumulator = Accumulator.new(consumer.to_s)
        Thread.current[KEY] = accumulator
        @mutex.synchronize { @active_count += 1 }
        yield
        accumulator.snapshot
      ensure
        Thread.current[KEY] = previous
        @mutex.synchronize { @active_count -= 1 }
      end

      # Plain integer read (GVL-atomic) — no `Thread.current` lookup on the disabled fast path.
      def active?
        @active_count.positive?
      end

      # Records one unresolved implicit-self call. No-op when no consumer is active on this thread (another
      # thread may have flipped {active?}).
      def record(class_name:, method_name:, node:, path:, line:, column:)
        accumulator = Thread.current[KEY]
        return if accumulator.nil?

        accumulator.add(
          UnresolvedSelfCall.new(
            class_name: class_name.to_s,
            method_name: method_name.to_sym,
            node: node,
            path: path,
            line: line,
            column: column
          )
        )
      end
    end
  end
end
