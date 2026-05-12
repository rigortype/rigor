# frozen_string_literal: true

require_relative "../trinary"

module Rigor
  module Type
    # A normalized non-empty union of two or more distinct types. Unions are
    # constructed exclusively through Rigor::Type::Combinator.union, which
    # flattens nested unions, deduplicates structurally-equal members, and
    # collapses single-member or empty results to the appropriate scalar
    # type. Direct calls to .new are an internal contract: callers MUST pass
    # an already-normalized members array.
    #
    # See docs/type-specification/normalization.md.
    class Union
      attr_reader :members

      def initialize(members)
        unless members.is_a?(Array) && members.size >= 2
          raise ArgumentError, "Union requires at least two members; use Combinator.union for normalization"
        end

        @members = members.freeze
        freeze
      end

      def describe(verbosity = :short)
        members.map { |m| m.describe(verbosity) }.join(" | ")
      end

      # ADR-1 § "RBS round-trip is lossless" + the value-lattice
      # rule `untyped | T = untyped` (every `T` is gradually
      # consistent with `untyped`). When any union member erases
      # to `"untyped"`, the whole union erases to `"untyped"` —
      # the RBS surface has no carrier for "Dynamic-origin
      # alongside a static facet", and the gradual-consistency
      # contract guarantees the substitution is sound at every
      # call site.
      #
      # Post-erasure dedupe removes `String | String` artefacts
      # that arise when two structurally-distinct `Constant`
      # carriers (e.g. `Constant<"Alice">` / `Constant<"Bob">`)
      # share an RBS-erased envelope. The members themselves
      # are already structurally deduped at construction by
      # `Type::Combinator.union`, but the post-erase strings
      # can collide.
      def erase_to_rbs
        erased = members.map(&:erase_to_rbs)
        return "untyped" if erased.include?("untyped")

        erased.uniq.join(" | ")
      end

      def top
        Trinary.no
      end

      def bot
        Trinary.no
      end

      def dynamic
        members.any? { |m| m.respond_to?(:dynamic) && m.dynamic.yes? } ? Trinary.maybe : Trinary.no
      end

      def accepts(other, mode: :gradual)
        Inference::Acceptance.accepts(self, other, mode: mode)
      end

      def ==(other)
        other.is_a?(Union) && members == other.members
      end
      alias eql? ==

      def hash
        [Union, members].hash
      end

      def inspect
        "#<Rigor::Type::Union #{describe(:short)}>"
      end
    end
  end
end
