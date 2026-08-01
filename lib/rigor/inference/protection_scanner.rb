# frozen_string_literal: true

require_relative "scope_indexer"
require_relative "origin_lookup"
require_relative "../source/node_walker"
require_relative "../analysis/check_rules/inferred_param_guard"

module Rigor
  module Inference
    # ADR-63 Tier 1 — the static type-protection proxy. Walks every dispatch site (a method call with an
    # explicit receiver) and classifies it by whether the receiver types to a concrete (non-`Dynamic`)
    # type — i.e. a site where Rigor's call rules *can* bite (undefined-method / wrong-arity /
    # argument-type-mismatch). A `Dynamic` / `Top` receiver (or a union with such an arm — gradually
    # valid) is *unprotected*: Rigor is blind there, and a type annotation on it would buy real catching
    # power.
    #
    # This is a sound UPPER BOUND on protection — a concrete receiver is necessary but not sufficient
    # for a diagnostic to actually fire — and it is one `type_of` pass, so it runs interactively and in
    # CI. The truth tier (does a diagnostic fire) is the phased mutation tier.
    class ProtectionScanner
      # A single unprotected call site.
      Site = Data.define(:line, :receiver, :method_name, :dynamic_origin)

      # `lower_bound_typed` is a split WITHIN `protected_count`, never a move out of it (issue #263):
      # a site whose receiver is concrete but rooted at a WD6b-marked inferred parameter (
      # {Analysis::CheckRules::InferredParamGuard.rooted?}) is a lower-bound type — `protected_count`
      # and `ratio` stay exactly as before, so `--threshold` never moves on unchanged code.
      FileResult = Data.define(:protected_count, :unprotected_count, :lower_bound_typed, :sites) do
        def total = protected_count + unprotected_count

        # Protected ratio; a file with no dispatch sites is vacuously fully protected (nothing to get
        # wrong).
        def ratio = total.zero? ? 1.0 : protected_count.to_f / total
      end

      def initialize(scope: nil)
        @scope = scope || Scope.empty
      end

      # @param root [Prism::Node] the parsed AST
      # @return [FileResult]
      def scan(root)
        index = ScopeIndexer.index(root, default_scope: @scope)
        protected_count = 0
        lower_bound_typed = 0
        sites = []

        Source::NodeWalker.each(root) do |node|
          next unless dispatch_site?(node)

          scope = index[node.receiver]
          receiver_type = scope.type_of(node.receiver)
          if concrete_receiver?(receiver_type)
            protected_count += 1
            lower_bound_typed += 1 if lower_bound_typed?(node.receiver, scope)
          else
            origin = OriginLookup.origin_for(scope, node.receiver)
            sites << Site.new(
              line: node.location.start_line,
              receiver: safe_describe(receiver_type),
              method_name: node.name.to_s,
              dynamic_origin: origin
            )
          end
        end

        FileResult.new(protected_count: protected_count, unprotected_count: sites.size,
                       lower_bound_typed: lower_bound_typed, sites: sites)
      end

      private

      def dispatch_site?(node)
        node.is_a?(Prism::CallNode) && !node.receiver.nil?
      end

      # A receiver Rigor can reason about: anything that is not `Dynamic` / `Top`, and (for a union)
      # only when every arm is concrete — a single `Dynamic` arm makes the whole call gradually valid,
      # so the rules stay silent there.
      def concrete_receiver?(type)
        case type
        when Type::Dynamic, Type::Top then false
        when Type::Union then type.members.all? { |member| concrete_receiver?(member) }
        else true
        end
      end

      # ADR-67 WD6b (issue #263) — true when a concrete receiver is rooted at an inferred-but-undeclared
      # parameter: the type is a call-site lower bound, so the negative in-body rules decline on it (no
      # diagnostic can actually fire here yet). Delegates to the single-homed shared predicate every
      # negative rule already consults — nothing is re-derived.
      def lower_bound_typed?(receiver, scope)
        Analysis::CheckRules::InferredParamGuard.rooted?(receiver, scope)
      end

      def safe_describe(type)
        type.respond_to?(:describe) ? type.describe(:short) : type.to_s
      rescue StandardError
        type.class.name
      end
    end
  end
end
