# frozen_string_literal: true

require_relative "../trinary"
require_relative "../value_semantics"
require_relative "acceptance_router"

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

      # Display-only adoption of two concise RBS spellings for the
      # union (see docs/type-specification/normalization.md § "Interaction
      # with display" and rbs-compatible-types.md § "Optionals"). Both are
      # purely cosmetic: `@members` keeps every carrier verbatim, so the
      # underlying type identity, RBS erasure, and round-trip are unchanged
      # — only the human-facing rendering reads like the RBS the user wrote.
      #
      #   * `true | false`           → `bool`   (the RBS boolean alias). The
      #     `bool` token leads the rendering, so `false | Foo | true` reads
      #     as `bool | Foo` rather than burying the pair mid-list.
      #   * `T | nil`                → `T?`     (the RBS optional sugar). Only
      #     applied when exactly one *logical* member remains beside `nil`,
      #     matching the rbs gem's own `to_s`: a multi-member union such as
      #     `Integer | String | nil` stays explicit rather than gaining a
      #     parenthesised `(Integer | String)?`. The two collapses compose,
      #     so `false | true | nil` reads as `bool?`.
      def describe(verbosity = :short)
        return "#{optional_inner(verbosity)}?" if optional?

        if boolean_pair?
          rest = members.reject { |m| boolean_literal?(m) }
          ["bool", *rest.map { |m| m.describe(verbosity) }].join(" | ")
        else
          members.map { |m| m.describe(verbosity) }.join(" | ")
        end
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

      include Rigor::Type::AcceptanceRouter

      include Rigor::ValueSemantics

      value_fields :members

      def inspect
        "#<Rigor::Type::Union #{describe(:short)}>"
      end

      private

      # Both `true` and `false` literals are present, so the pair can
      # render as `bool`. A union carrying only one of them stays a
      # plain literal (`true` / `false`) — that asymmetry is meaningful.
      def boolean_pair?
        members.any? { |m| boolean_literal?(m, true) } &&
          members.any? { |m| boolean_literal?(m, false) }
      end

      def boolean_literal?(member, which = :either)
        return false unless member.is_a?(Constant)

        case which
        when :either then member.value.equal?(true) || member.value.equal?(false)
        else member.value.equal?(which)
        end
      end

      def nil_literal?(member)
        member.is_a?(Constant) && member.value.nil?
      end

      # `nil` is present and, once the `bool` pair is treated as a
      # single logical member, exactly one non-`nil` member remains —
      # so the whole union renders as `T?`. Counting the bool pair as
      # one is what lets `false | true | nil` reach `bool?`.
      def optional?
        return false unless members.any? { |m| nil_literal?(m) }

        significant = members.reject { |m| nil_literal?(m) }
        logical = significant.size - (boolean_pair? ? 1 : 0)
        logical == 1
      end

      def optional_inner(verbosity)
        return "bool" if boolean_pair?

        members.find { |m| !nil_literal?(m) }.describe(verbosity)
      end
    end
  end
end
