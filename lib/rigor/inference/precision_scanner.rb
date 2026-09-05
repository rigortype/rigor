# frozen_string_literal: true

require_relative "../source/node_walker"
require_relative "../scope"
require_relative "scope_indexer"

module Rigor
  module Inference
    # Measures the *type quality* of inferred expressions — not whether the engine recognises an AST node
    # class (that is `CoverageScanner`'s job), but whether the type it produces carries useful static
    # information.
    #
    # Each visited *expression* node is classified into one of eight precision tiers (non-expression syntax
    # nodes — argument / parameter lists, parameter declarations, hash pairs, statement wrappers, clause
    # headers — are skipped; see {NON_EXPRESSION_NODE_TYPES}):
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
    # The summary exposes `precision_ratio` (constant+nominal+shaped+refined+bot over total) and
    # `opaque_ratio` (dynamic_top+top over total).
    #
    # For Union types the *worst* member tier is used, since the union is only as precise as its
    # least-precise constituent. Intersection uses the *best* member (the most specific side wins).
    # Difference follows its base type.
    class PrecisionScanner
      TIERS = %i[
        constant nominal shaped refined bot
        dynamic_specific dynamic_top top
      ].freeze

      # Prism node classes that do not denote a value-producing expression, so typing them is meaningless —
      # they have no runtime value to carry a type. Counting them (they always fall to the `dynamic_top`
      # fallback) silently diluted the precision ratio: on a real survey target (shugo/textbringer) they
      # were ~49% of every "opaque" node, dragging the headline number ~13 points below the true
      # expression-level precision. We exclude them from BOTH numerator and denominator so the ratio
      # measures what it claims to — the type quality of actual expressions.
      #
      # The set is deliberately CONSERVATIVE: only nodes that are unambiguously non-expressions in Ruby's
      # grammar are listed — argument / parameter list containers and the parameter declarations inside
      # them; the `key => value` pair node (its key and value are themselves walked and counted); the
      # program / statements sequence wrappers (their value is the last child, already counted — listing
      # them avoids double-counting); and the clause-header nodes whose body, not the header, carries the
      # value. Anything that *could* be a value expression (`BlockNode`, `BeginNode`, `ImplicitNode`,
      # `ParenthesesNode`, splats, …) is left in so a genuine inference gap stays visible.
      #
      # Compared by class NAME so a Prism version that lacks one of the newer node classes does not break
      # loading.
      NON_EXPRESSION_NODE_TYPES = %w[
        Prism::ProgramNode
        Prism::StatementsNode
        Prism::ArgumentsNode
        Prism::BlockArgumentNode
        Prism::ParametersNode
        Prism::BlockParametersNode
        Prism::NumberedParametersNode
        Prism::ItParametersNode
        Prism::KeywordHashNode
        Prism::RequiredParameterNode
        Prism::OptionalParameterNode
        Prism::RestParameterNode
        Prism::KeywordRestParameterNode
        Prism::BlockParameterNode
        Prism::RequiredKeywordParameterNode
        Prism::OptionalKeywordParameterNode
        Prism::ForwardingParameterNode
        Prism::NoKeywordsParameterNode
        Prism::ImplicitRestNode
        Prism::AssocNode
        Prism::AssocSplatNode
        Prism::WhenNode
        Prism::InNode
        Prism::ElseNode
        Prism::EnsureNode
        Prism::RescueNode
      ].to_set.freeze

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
      def scan(root)
        scope_index = ScopeIndexer.index(root, default_scope: @scope)
        tier_counts = TIERS.to_h { |t| [t, 0] }
        total = 0

        Source::NodeWalker.each(root) do |node|
          next if NON_EXPRESSION_NODE_TYPES.include?(node.class.name)

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
        when Type::Nominal, Type::Singleton,
             Type::DataClass, Type::StructClass then :nominal
        when Type::Tuple, Type::HashShape,
             Type::IntegerRange, Type::App,
             Type::DataInstance, Type::StructInstance,
             Type::BoundMethod                  then :shaped
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
