# frozen_string_literal: true

require "prism"

module Rigor
  module Source
    # Issue #992 — the positional-argument envelope of a `Prism::DefNode`, and the ONE place a `def` nobody
    # declared is turned into something `call.wrong-arity` can check a call against.
    #
    # Both undeclared lanes read it. A method known only to the discovery walk has no other shape, and a
    # method `rigor-rbs-inline` synthesized a fully defaulted skeleton for (`%a{rigor:v1:inferred-signature}`)
    # is sent here too rather than having its synthesized member's arity read, so a `def` can never be
    # judged by two parsers of its parameter list that disagree.
    #
    # An envelope is plain frozen data, `[min, max, required_keywords]`, because it rides the ADR-85 seed
    # bundle through `Marshal`: `max` is nil when a rest or `...` parameter leaves it unbounded, and
    # `required_keywords` is true when the def takes a required keyword — a call that passes positionals
    # only then fails on the missing keyword whatever its count, which is a different diagnostic than the
    # one this envelope backs, so the rule declines on it the way `compute_arity_envelope` declines an RBS
    # function with required keywords.
    #
    # {OPAQUE} is the value every other contribution to a name records — `define_method`, `attr_*`, an alias,
    # a macro that names the method, a second `def` whose envelope differs — and it absorbs under {.merge}.
    # That makes the per-name fold a join: order-independent, idempotent, and unable to keep one of several
    # shapes silently.
    module ParameterEnvelope
      module_function

      OPAQUE = :opaque

      # The envelope of `def_node`'s own parameter list. Block, keyword-optional and keyword-rest parameters
      # never change how many positionals the method accepts; `super`, `yield` and `&block` in the body do
      # not either, so the body is not read at all.
      def of(def_node)
        params = def_node.parameters
        return [0, 0, false].freeze if params.nil?

        required = params.requireds.size + params.posts.size
        [required, maximum(params, required), required_keywords?(params)].freeze
      end

      def maximum(params, required)
        return nil if params.rest || params.keyword_rest.is_a?(Prism::ForwardingParameterNode)

        required + params.optionals.size
      end

      def required_keywords?(params)
        params.keywords.any?(Prism::RequiredKeywordParameterNode)
      end

      # The join of two contributions to one name: equal envelopes stay, anything else is {OPAQUE}.
      def merge(left, right)
        return right if left.nil?
        return left if right.nil?

        left == right ? left : OPAQUE
      end

      def opaque?(envelope) = envelope == OPAQUE

      # Folds `overlay`'s per-class entries into `base` with {.merge}, returning a new table. Both are
      # `{class name => {key => envelope}}`.
      def merge_tables(base, overlay)
        return overlay if base.nil? || base.empty?
        return base if overlay.nil? || overlay.empty?

        base.merge(overlay) { |_class, left, right| left.merge(right) { |_key, a, b| merge(a, b) } }
      end
    end
  end
end
