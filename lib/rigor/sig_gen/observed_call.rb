# frozen_string_literal: true

module Rigor
  module SigGen
    # Per-call-site argument observation produced by
    # {ObservationCollector}. ADR-14 follow-up: the earlier
    # MVP shape (`Array[Type]` of positional types only)
    # could not represent keyword arguments — every call like
    # `MethodCatalog.new(path: ..., mutating_selectors: ...)`
    # discarded the whole observation via `non_positional?`.
    # The new shape carries positional and keyword arg types
    # in parallel so the per-position / per-keyword unions
    # can each be reconstructed independently.
    #
    # The carrier is intentionally minimal:
    # - `positional` — frozen Array of `Rigor::Type` per
    #   positional argument, in call-site order.
    # - `keyword` — frozen Hash mapping each keyword
    #   argument's Symbol name to its `Rigor::Type`.
    #
    # Generator-side callers also accept a legacy shape
    # (plain Array of types) for backward compatibility with
    # specs that constructed observations directly before
    # this carrier existed; `ObservedCall.from(...)` does the
    # lift.
    class ObservedCall
      attr_reader :positional, :keyword

      def initialize(positional: [], keyword: {})
        @positional = positional.freeze
        @keyword = keyword.freeze
        freeze
      end

      def empty?
        positional.empty? && keyword.empty?
      end

      def ==(other)
        other.is_a?(ObservedCall) && positional == other.positional && keyword == other.keyword
      end
      alias eql? ==

      def hash
        [ObservedCall, positional, keyword].hash
      end

      # Lifts the legacy plain-Array shape into an
      # `ObservedCall` carrier. Already-lifted values pass
      # through unchanged. Used by `Generator#initialize`'s
      # observations-normalisation pass so spec fixtures
      # written against the slice-3 surface keep working.
      def self.from(value)
        case value
        when ObservedCall then value
        when Array then new(positional: value)
        else raise ArgumentError, "expected Array or ObservedCall, got #{value.class}"
        end
      end
    end
  end
end
