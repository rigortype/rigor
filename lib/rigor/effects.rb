# frozen_string_literal: true

require_relative "effects/label"
require_relative "effects/label_set"
require_relative "effects/registry"
require_relative "effects/taint_cause"
require_relative "effects/catalog"
require_relative "effects/collector"
require_relative "effects/effect_table"
require_relative "effects/file_collection"
require_relative "effects/origin"
require_relative "effects/propagator"
require_relative "effects/summary"

module Rigor
  # The effect-label vocabulary (ADR-103; normative in
  # `docs/type-specification/effect-labels.md`).
  #
  # Two layers live here. The label *language* — the grammar, the subsumption relation, the label
  # sets a summary and an envelope are made of, the registry that says which spellings are
  # recognised, and the closed enum of taint causes. And, on top of it, the observational machinery
  # of #379: the {Collector} that records what the typer decided, the {Summary} / {FileCollection}
  # values it produces, the built-in {Catalog}, and the {Propagator} that closes them into an
  # {EffectTable}. Nothing here judges anything — the effect snapshot (#381), the annotation
  # surfaces (#383) and the diagnostics (#384) land as their own slices on top.
  #
  # "Effect label", "effect summary" and "effect envelope" are trapped compounds in `CONTEXT.md`;
  # bare "effect" still names `Rigor::FlowContribution`'s flow-effect bundle.
  module Effects
  end
end
