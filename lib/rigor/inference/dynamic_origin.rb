# frozen_string_literal: true

module Rigor
  module Inference
    # ADR-75 v1 cause set — precision-additive provenance for Dynamic[T] introduction sites. Each symbol
    # identifies a distinct family of reason that an expression widened to Dynamic, surfaced by
    # `rigor coverage --protection` so users can distinguish tractable holes (e.g. an explicit `untyped` RBS
    # signature) from intractable ones (e.g. unsupported syntax).
    #
    # Provenance is a side-channel: it never participates in subtyping, consistency, normalization, or
    # erasure, and no diagnostic fires from it.
    module DynamicOrigin
      # A gem with no resolvable RBS.
      EXTERNAL_GEM_WITHOUT_RBS = :external_gem_without_rbs
      # Value across macro/DSL expansion or plugin-declared dynamic return.
      FRAMEWORK_DSL_BOUNDARY  = :framework_dsl_boundary
      # Budget/fuel guard widened to Dynamic.
      ANALYZER_BUDGET_CUTOFF  = :analyzer_budget_cutoff
      # Authored `untyped` contract.
      EXPLICIT_UNTYPED        = :explicit_untyped
      # The engine cannot yet infer a value's type although it is not unmodeled syntax and no RBS declared
      # it `untyped`: a resolved user/ancestor method whose return body it cannot fold, or an undeclared
      # method *parameter* with no call-site type flowing in (`def f(x); x.foo`). The lever is inference —
      # parameter inference (ADR-67) or ivar-field typing (ADR-58) — not a hand-written type, so it is an
      # engine gap that routes to that roadmap rather than to "add RBS". (The `_return_` in the name is
      # historical; it now covers the parameter case too.)
      INFERRED_RETURN_UNTYPED = :inferred_return_untyped
      # Inference fallback on unmodeled construct.
      UNSUPPORTED_SYNTAX      = :unsupported_syntax

      CAUSES = [
        EXTERNAL_GEM_WITHOUT_RBS,
        FRAMEWORK_DSL_BOUNDARY,
        ANALYZER_BUDGET_CUTOFF,
        EXPLICIT_UNTYPED,
        INFERRED_RETURN_UNTYPED,
        UNSUPPORTED_SYNTAX
      ].freeze

      # ADR-73 P6 / ADR-75 WD2 — tractability: given the cause, can a user close this `Dynamic` hole, and on
      # which axis. `coverage --protection` surfaces it so a user does not chase a hole a hand-written type
      # cannot fix. Three coarse, action-oriented categories:
      #
      # - `:add_rbs`      — write or install RBS (a missing gem signature, or an authored `untyped` to
      #                     tighten).
      # - `:enable_plugin`— a framework / DSL boundary; needs a plugin or `pre_eval:`, not a hand-written type.
      # - `:engine_gap`   — not user-closable (a budget cutoff or unmodeled syntax); report it.
      ADD_RBS       = :add_rbs
      ENABLE_PLUGIN = :enable_plugin
      ENGINE_GAP    = :engine_gap

      TRACTABILITY = {
        EXTERNAL_GEM_WITHOUT_RBS => ADD_RBS,
        EXPLICIT_UNTYPED => ADD_RBS,
        FRAMEWORK_DSL_BOUNDARY => ENABLE_PLUGIN,
        ANALYZER_BUDGET_CUTOFF => ENGINE_GAP,
        INFERRED_RETURN_UNTYPED => ENGINE_GAP,
        UNSUPPORTED_SYNTAX => ENGINE_GAP
      }.freeze

      module_function

      # @return [Symbol, nil] the tractability category for a cause, or nil when the cause is unknown /
      #   absent.
      def tractability(cause)
        TRACTABILITY[cause]
      end
    end
  end
end
