# frozen_string_literal: true

require_relative "dependency_source_inference/boundary_cross_reporter"
require_relative "dependency_source_inference/gem_resolver"
require_relative "dependency_source_inference/index"
require_relative "dependency_source_inference/walker"
require_relative "dependency_source_inference/builder"

module Rigor
  module Analysis
    # Implementation of [ADR-10 — Opt-in dependency-source
    # inference](../../../docs/adr/10-dependency-source-inference.md).
    #
    # The namespace coordinates three components:
    #
    # - {GemResolver} maps a
    #   `Configuration::Dependencies::Entry` to either a frozen
    #   `Resolved(gem_name, version, gem_dir, mode, roots)` or an
    #   `Unresolvable(gem_name, reason)` value.
    # - {Builder.build} folds a `Configuration::Dependencies`
    #   into a frozen {Index} carrying the partitioned outcomes.
    # - {Index} holds the per-run state the dispatcher tier
    #   consults via `#contribution_for`. Slice 2a ships the
    #   stub returning `nil`; slice 2b populates the method
    #   table by walking each resolved gem's `roots:`.
    #
    # Per the ADR's "Implementation slicing" section, slice 2 is
    # split internally:
    #
    # - Slice 2a (this commit): gem resolution, index plumbing,
    #   `Analysis::Runner` wiring, `dynamic.dependency-source.gem-not-found`
    #   diagnostic for unresolvable entries.
    # - Slice 2b (next commit): walker, dispatcher tier
    #   integration, `Type::Dynamic`-wrapped returns.
    module DependencySourceInference
    end
  end
end
