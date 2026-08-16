# frozen_string_literal: true

require_relative "effects/label"
require_relative "effects/label_set"
require_relative "effects/registry"
require_relative "effects/taint_cause"

module Rigor
  # The effect-label vocabulary (ADR-103; normative in
  # `docs/type-specification/effect-labels.md`).
  #
  # This namespace is the label *language* only — the grammar, the subsumption relation, the label
  # sets a summary and an envelope are made of, the registry that says which spellings are
  # recognised, and the closed enum of taint causes. Nothing here collects, propagates or judges
  # anything: summary collection (#379), the effect snapshot (#381), the annotation surfaces (#383)
  # and the diagnostics (#384) land as their own slices on top of it.
  #
  # "Effect label", "effect summary" and "effect envelope" are trapped compounds in `CONTEXT.md`;
  # bare "effect" still names `Rigor::FlowContribution`'s flow-effect bundle.
  module Effects
  end
end
