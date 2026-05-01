# frozen_string_literal: true

require_relative "fallback"

module Rigor
  module Inference
    # Mutable observer that accumulates Rigor::Inference::Fallback events
    # emitted by the type-inference engine. Pass an instance to
    # Rigor::Scope#type_of(node, tracer: ...) to record every fail-soft
    # fallback. The tracer MUST NOT change the return value of type_of;
    # see docs/internal-spec/inference-engine.md (Fail-Soft Policy).
    #
    # Future slices may add additional record_* methods (e.g.
    # record_dispatch_miss for Slice 3, record_budget_cutoff for Slice 5);
    # the namespaced method names exist so a single tracer can collect
    # multiple event families without confusing them.
    class FallbackTracer
      def initialize
        @events = []
      end

      def events
        @events.dup.freeze
      end

      def record_fallback(event)
        raise ArgumentError, "expected Rigor::Inference::Fallback, got #{event.class}" unless event.is_a?(Fallback)

        @events << event
        self
      end

      def empty?
        @events.empty?
      end

      def size
        @events.size
      end

      def each(&block)
        return @events.each unless block

        @events.each(&block)
        self
      end

      include Enumerable

      def kinds
        @events.map(&:node_class).uniq
      end

      def families
        @events.map(&:family).uniq
      end

      def clear
        @events.clear
        self
      end
    end
  end
end
