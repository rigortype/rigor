# frozen_string_literal: true

require_relative "effects/label"
require_relative "effects/label_set"
require_relative "effects/registry"
require_relative "effects/taint_cause"
require_relative "effects/catalog"
require_relative "effects/collector"
require_relative "effects/effect_table"
require_relative "effects/envelope"
require_relative "effects/envelope_check"
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
  # {EffectTable}. On top of both sits the one thing here that DOES judge: an {Envelope} — an
  # author-declared upper bound read off the project's RBS — and the {EnvelopeCheck} that compares it
  # against what the run proved, which is where `effect.envelope-exceeded` is decided (#383). The
  # effect snapshot (#381) and the vocabulary diagnostic (#384) are their own slices.
  #
  # "Effect label", "effect summary" and "effect envelope" are trapped compounds in `CONTEXT.md`;
  # bare "effect" still names `Rigor::FlowContribution`'s flow-effect bundle.
  module Effects
  end
end
