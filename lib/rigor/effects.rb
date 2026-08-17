# frozen_string_literal: true

require_relative "effects/label"
require_relative "effects/label_set"
require_relative "effects/registry"
require_relative "effects/taint_cause"
require_relative "effects/attribution"
require_relative "effects/catalog"
require_relative "effects/collector"
require_relative "effects/config_envelopes"
require_relative "effects/discharge"
require_relative "effects/effect_table"
require_relative "effects/envelope"
require_relative "effects/envelope_check"
require_relative "effects/envelope_index"
require_relative "effects/file_collection"
require_relative "effects/liskov_check"
require_relative "effects/method_key"
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
  # author-declared upper bound read off the project's RBS or written by convention in `.rigor.yml`
  # ({ConfigEnvelopes}) — and the two checks that judge one: {EnvelopeCheck} compares a method against
  # its own bound (`effect.envelope-exceeded`, #383 / #385) and {LiskovCheck} an override against the
  # bound it inherits (`effect.liskov-widened`, #386). The same declarations are read a third way, which
  # judges nothing: {EnvelopeIndex} resolves them per CALL SITE, so a caller reads what its callee
  # promised as a `≤` bound. Beside them sit the project's policy
  # surfaces: {Attribution} colours code Rigor never analysed, into the declared lane, and {Discharge}
  # applies `effects.tolerated:` per origin at judgment time. The effect snapshot (#381) and the
  # vocabulary diagnostic (#384) are their own slices.
  #
  # "Effect label", "effect summary" and "effect envelope" are trapped compounds in `CONTEXT.md`;
  # bare "effect" still names `Rigor::FlowContribution`'s flow-effect bundle.
  module Effects
  end
end
