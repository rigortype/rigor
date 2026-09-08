# frozen_string_literal: true

require_relative "../trinary"
require_relative "../value_semantics"

module Rigor
  module Type
    # Immutable value object returned by `Rigor::Type#accepts(other, mode:)`. Carries the three-valued
    # answer alongside the boundary mode the answer was computed under and an ordered list of textual
    # reasons describing which rules fired.
    #
    # AcceptsResult is the dual of `SubtypeResult` (Slice 5+). Acceptance answers "is `other` passable to
    # `self` at a method-parameter or assignment boundary?", consulting the gradual-typing rules in
    # docs/type-specification/value-lattice.md when `mode` is `:gradual`, and the strict subset relation
    # when `mode` is `:strict`. Phase 2c ships full `:gradual` semantics; `:strict` is reserved for later
    # slices and currently raises ArgumentError.
    #
    # Reasons are stored as plain strings for now. Slice 5+ MAY upgrade them to structured records (rule
    # id, supporting facts, dynamic provenance); callers MUST treat the reasons array as opaque except for
    # human-readable logging.
    #
    # See docs/internal-spec/internal-type-api.md ("Result Value Objects").
    class AcceptsResult
      MODES = %i[gradual strict].freeze
      private_constant :MODES

      attr_reader :trinary, :mode, :reasons

      # @param trinary [Rigor::Trinary]
      # @param mode [Symbol] currently `:gradual` (default) or `:strict`.
      # @param reasons [Array<String>, String, nil] textual reasons; a
      #   single string is wrapped, `nil` becomes an empty array.
      def initialize(trinary, mode: :gradual, reasons: nil)
        raise ArgumentError, "trinary must be Rigor::Trinary, got #{trinary.class}" unless trinary.is_a?(Trinary)
        raise ArgumentError, "mode must be one of #{MODES.inspect}, got #{mode.inspect}" unless MODES.include?(mode)

        @trinary = trinary
        @mode = mode
        @reasons = normalize_reasons(reasons).freeze
        freeze
      end

      class << self
        def yes(mode: :gradual, reasons: nil)
          literal_result(Trinary.yes, mode, reasons)
        end

        def no(mode: :gradual, reasons: nil)
          literal_result(Trinary.no, mode, reasons)
        end

        def maybe(mode: :gradual, reasons: nil)
          literal_result(Trinary.maybe, mode, reasons)
        end

        private

        # #775 — a result is an immutable value, so one instance serves every site that asks for the same
        # verdict with the same literal reason (`"structural equality"`, `"exact name match"`, ...): the
        # acceptance rules answer ~360k times on the lib self-check, most of them through a handful of
        # such literals, and each answer cost the result plus its reasons array. A reason built at the
        # site (an unfrozen interpolated String) or a reason list still builds a fresh result.
        def literal_result(trinary, mode, reasons)
          literal = reasons.nil? || (reasons.is_a?(String) && reasons.frozen?)
          return new(trinary, mode: mode, reasons: reasons) unless literal

          by_mode = (@literal_results[trinary] ||= {})
          by_reason = (by_mode[mode] ||= {})
          by_reason[reasons] ||= new(trinary, mode: mode, reasons: reasons)
        end
      end

      # `Trinary` verdict => mode => literal reason (or nil) => the shared result.
      @literal_results = {}

      def yes?
        trinary.yes?
      end

      def no?
        trinary.no?
      end

      def maybe?
        trinary.maybe?
      end

      # Returns a new AcceptsResult whose reasons list is `self.reasons`
      # with `reason` appended. Used by combinator-style routing in
      # {Rigor::Inference::Acceptance} to thread context through nested
      # acceptance checks without mutating any object.
      def with_reason(reason)
        return self if reason.nil? || reason.empty?

        self.class.new(trinary, mode: mode, reasons: reasons + [reason])
      end

      include Rigor::ValueSemantics

      value_fields :trinary, :mode, :reasons

      def inspect
        "#<Rigor::Type::AcceptsResult #{trinary.inspect} mode=#{mode}>"
      end

      private

      def normalize_reasons(reasons)
        case reasons
        when nil then []
        when Array then reasons.dup
        else [reasons.to_s]
        end
      end
    end
  end
end
