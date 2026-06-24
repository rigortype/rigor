# frozen_string_literal: true

module Rigor
  module Inference
    # ADR-75 v1 cause set — precision-additive provenance for Dynamic[T]
    # introduction sites.  Each symbol identifies a distinct family of
    # reason that an expression widened to Dynamic, surfaced by
    # `rigor coverage --protection` so users can distinguish tractable
    # holes (e.g. an explicit `untyped` RBS signature) from intractable
    # ones (e.g. unsupported syntax).
    #
    # Provenance is a side-channel: it never participates in subtyping,
    # consistency, normalization, or erasure, and no diagnostic fires
    # from it.
    module DynamicOrigin
      # A gem with no resolvable RBS.
      EXTERNAL_GEM_WITHOUT_RBS = :external_gem_without_rbs
      # Value across macro/DSL expansion or plugin-declared dynamic return.
      FRAMEWORK_DSL_BOUNDARY  = :framework_dsl_boundary
      # Budget/fuel guard widened to Dynamic.
      ANALYZER_BUDGET_CUTOFF  = :analyzer_budget_cutoff
      # Authored `untyped` contract.
      EXPLICIT_UNTYPED        = :explicit_untyped
      # Inference fallback on unmodeled construct.
      UNSUPPORTED_SYNTAX      = :unsupported_syntax

      CAUSES = [
        EXTERNAL_GEM_WITHOUT_RBS,
        FRAMEWORK_DSL_BOUNDARY,
        ANALYZER_BUDGET_CUTOFF,
        EXPLICIT_UNTYPED,
        UNSUPPORTED_SYNTAX
      ].freeze
    end
  end
end
