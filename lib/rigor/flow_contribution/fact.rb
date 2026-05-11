# frozen_string_literal: true

module Rigor
  class FlowContribution
    # Canonical slot payload for the four edge-aware fact slots
    # (`truthy_facts`, `falsey_facts`, `post_return_facts`, plus
    # the equivalent under `mutations` / `invalidations` /
    # `role_conformance` once those carriers grow Fact-shaped
    # variants).
    #
    # ADR-7 § "Slice 4-A" pins this object as the **single
    # canonical translation target** for the four parallel
    # contribution carriers the engine has carried so far:
    #
    # 1. Built-in narrowing rules' direct fact emission
    #    (Inference::Narrowing#predicate_scopes).
    # 2. RBS::Extended `predicate-if-*` directives
    #    (`Rigor::RbsExtended::PredicateEffect`).
    # 3. RBS::Extended `assert*` directives
    #    (`Rigor::RbsExtended::AssertEffect`).
    # 4. Future plugin contributions (slice 5 emission protocol).
    #
    # Each of those four carriers translates to / from Fact at
    # its boundary; downstream of {Rigor::FlowContribution#to_element_list}
    # and {Rigor::FlowContribution::Merger.merge}, every slot
    # payload is a Fact (or a value that the merger compares by
    # equality and never inspects). The typed `RbsExtended::*Effect`
    # carriers stay internal to the parser side — they hold the
    # source-text shape, but lose their identity at the
    # `read_flow_contribution` boundary.
    #
    # ## Field set
    #
    # - `target_kind`: `:parameter` (call-site argument) or
    #   `:self` (receiver). Future slices may extend the set
    #   (`:local`, `:ivar`, `:result`); the merger is agnostic
    #   to the concrete kinds and only requires equality.
    # - `target_name`: a `Symbol`. For `:parameter` it's the
    #   declared parameter name. For `:self` it is the literal
    #   `:self` symbol so the field stays non-nil and the merge
    #   key is well-defined.
    # - `type`: a `Rigor::Type::*` (Nominal, Refined,
    #   IntegerRange, Difference, …) the fact narrows the
    #   target toward (when `negative` is false) or away from
    #   (when `negative` is true).
    # - `negative`: `true` for the `~T` negation form
    #   (`predicate-if-true x is ~Integer`), `false` for the
    #   plain positive form. Mirrors the `negative` field on
    #   `PredicateEffect` / `AssertEffect`.
    #
    # The `target` accessor returns `:self` for self-targeted
    # facts and `[:parameter, name]` otherwise — that's the
    # value {Element#target} keys on, so two facts that narrow
    # the same parameter from different contribution sources
    # land in the same merge bucket.
    FACT_VALID_TARGET_KINDS = %i[parameter self].freeze

    class Fact < Data.define(:target_kind, :target_name, :type, :negative)
      def initialize(target_kind:, target_name:, type:, negative: false)
        unless FACT_VALID_TARGET_KINDS.include?(target_kind)
          raise ArgumentError,
                "FlowContribution::Fact target_kind must be one of " \
                "#{FACT_VALID_TARGET_KINDS.inspect}, got #{target_kind.inspect}"
        end

        unless target_name.is_a?(Symbol)
          raise ArgumentError,
                "FlowContribution::Fact target_name must be a Symbol, got #{target_name.inspect}"
        end

        super
      end

      # Composite target identifier the merger keys on. `:self`
      # for self-targeted facts; otherwise `[:parameter, name]`
      # so two contributions that narrow the same parameter
      # (regardless of source family) land in the same merge
      # bucket.
      def target
        target_kind == :self ? :self : [target_kind, target_name]
      end

      def negative?
        negative == true
      end
    end
  end
end
