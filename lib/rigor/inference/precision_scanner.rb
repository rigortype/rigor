# frozen_string_literal: true

require_relative "../source/node_walker"
require_relative "../scope"
require_relative "scope_indexer"

module Rigor
  module Inference
    # Measures the *type quality* of inferred expressions — not whether the
    # engine recognises an AST node class (that is `CoverageScanner`'s job),
    # but whether the type it produces carries useful static information.
    #
    # Each visited node is classified into one of eight precision tiers:
    #
    #   :constant         — Constant[T]: literal value known exactly
    #   :nominal          — Nominal/Singleton: class identity known
    #   :shaped           — Tuple/HashShape/IntegerRange/App: structure known
    #   :refined          — Refined: narrowed by a predicate/assertion
    #   :bot              — Bot: unreachable branch (definitively precise)
    #   :dynamic_specific — Dynamic[X] where X is not Top: origin partial
    #   :dynamic_top      — Dynamic[Top]: completely opaque (the "untyped" hole)
    #   :top              — Top: universal supertype (no information)
    #
    # The summary exposes `precision_ratio` (constant+nominal+shaped+refined+bot
    # over total) and `opaque_ratio` (dynamic_top+top over total).
    #
    # For Union types the *worst* member tier is used, since the union is only
    # as precise as its least-precise constituent. Intersection uses the *best*
    # member (the most specific side wins). Difference follows its base type.
    class PrecisionScanner
      TIERS = %i[
        constant nominal shaped refined bot
        dynamic_specific dynamic_top top
      ].freeze

      TIER_RANK = TIERS.each_with_index.to_h.freeze
      private_constant :TIER_RANK

      PRECISE_TIERS = %i[constant nominal shaped refined bot].to_set.freeze
      private_constant :PRECISE_TIERS

      # Per-file result. Immutable value object.
      class FileResult < Data.define(:total, :tier_counts)
        def precise_count
          PRECISE_TIERS.sum { |t| tier_counts.fetch(t, 0) }
        end

        def dynamic_top_count
          tier_counts.fetch(:dynamic_top, 0)
        end

        def dynamic_specific_count
          tier_counts.fetch(:dynamic_specific, 0)
        end

        def dynamic_count
          dynamic_top_count + dynamic_specific_count
        end

        def opaque_count
          tier_counts.fetch(:dynamic_top, 0) + tier_counts.fetch(:top, 0)
        end

        def precision_ratio
          return 1.0 if total.zero?

          precise_count.fdiv(total)
        end

        def opaque_ratio
          return 0.0 if total.zero?

          opaque_count.fdiv(total)
        end
      end

      # @param scope [Rigor::Scope] base scope for type inference.
      def initialize(scope: nil)
        @scope = scope || Scope.empty
      end

      # @param root [Prism::Node] the parsed AST
      # @return [FileResult]
      def scan(root)
        scope_index = ScopeIndexer.index(root, default_scope: @scope)
        tier_counts = TIERS.to_h { |t| [t, 0] }
        total = 0

        Source::NodeWalker.each(root) do |node|
          type = scope_index[node].type_of(node)
          tier = classify(type)
          tier_counts[tier] += 1
          total += 1
        end

        FileResult.new(total: total, tier_counts: tier_counts)
      end

      private

      def classify(type)
        case type
        when Type::Bot                          then :bot
        when Type::Top                          then :top
        when Type::Constant                     then :constant
        when Type::Nominal, Type::Singleton     then :nominal
        when Type::Tuple, Type::HashShape,
             Type::IntegerRange, Type::App      then :shaped
        when Type::Refined                      then :refined
        when Type::Dynamic                      then classify_dynamic(type)
        when Type::Union                        then worst_of(type.members)
        when Type::Intersection                 then best_of(type.members)
        when Type::Difference                   then classify(type.base)
        else                                         :dynamic_top
        end
      end

      def classify_dynamic(type)
        type.static_facet.is_a?(Type::Top) ? :dynamic_top : :dynamic_specific
      end

      def worst_of(members)
        members.map { |m| classify(m) }.max_by { |t| TIER_RANK[t] } || :dynamic_top
      end

      def best_of(members)
        members.map { |m| classify(m) }.min_by { |t| TIER_RANK[t] } || :dynamic_top
      end
    end
  end
end
