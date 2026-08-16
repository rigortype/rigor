# frozen_string_literal: true

require_relative "label_set"
require_relative "summary"

module Rigor
  module Effects
    # An author-declared upper bound on one method's effect labels (ADR-103 WD1; normative in
    # `docs/type-specification/effect-labels.md` § Effect envelopes).
    #
    # Four facts and one seam:
    #
    # - {#owner_key} — the method key the envelope binds (`Class#m` / `Class.m`). A class-level
    #   envelope is read once and {#rebind}ed onto each method of that class discovery knows.
    # - {#bound} — the {LabelSet} the method's proven labels must be subsumed by. {LabelSet::TOP}
    #   means "no envelope": the fail-open reading a tag carrying an unknown label degrades to.
    # - {#source} — which spelling produced it: `:pure_annotation` (`%a{pure}`),
    #   `:effect_annotation` (`%a{rigor:v1:effect …}` on the method) or `:class_annotation` (either
    #   spelling on the class / module declaration, which is also what {#rebind} stamps — what matters
    #   downstream is that the bound was distributed rather than written on the method).
    # - {#location} — `path:line` of the annotation, so the diagnostic can name where the bound was
    #   written; {#spelling} is the author's own text, quoted back verbatim.
    # - {#unknown_labels} — the well-formed-but-unrecognised spellings that made this envelope read
    #   ⊤ ([#384](https://github.com/rigortype/rigor/issues/384)'s `effect.unknown-label` reads it).
    #   Empty otherwise.
    # - {#declared_labels} — every token the tag listed, in source order, recognised or not (empty
    #   for `%a{pure}`, whose bound is written by its spelling rather than by a list). It is what
    #   answers "was some OTHER member of this list known?", one of the four signals
    #   {LabelIntent} reads intent off.
    #
    # `mutate.local` is tolerated by **every** envelope, `%a{pure}` included: a method may freely
    # mutate what its own frame allocated and never let escape.
    class Envelope < Data.define(:owner_key, :bound, :source, :location, :spelling, :unknown_labels,
                                 :declared_labels)
      NO_LABELS = [].freeze
      private_constant :NO_LABELS

      def self.build(owner_key:, bound:, source:, location: nil, spelling: nil, unknown_labels: NO_LABELS,
                     declared_labels: NO_LABELS)
        new(
          owner_key: owner_key, bound: bound, source: source, location: location,
          spelling: spelling, unknown_labels: unknown_labels.uniq.sort.freeze,
          declared_labels: declared_labels.dup.freeze
        )
      end

      # Whether this reads as ⊤ — no bound at all. An unknown label degrades the whole tag here, so a
      # typo suppresses findings rather than inventing them (the fail-open rule).
      def top?
        bound.top?
      end

      # Whether `label` is inside the bound. `mutate.local` always is.
      def tolerates?(label)
        bound.admits?(label) || Summary::TRIVIAL_BOUND.admits?(label)
      end

      # The members of `label_set` this envelope does NOT admit, sorted. One diagnostic per member.
      def exceeded_by(label_set)
        return NO_LABELS if top?

        label_set.to_a.reject { |label| tolerates?(label) }
      end

      # The same bound, attached to another method key — how a class-level envelope reaches each
      # method of its class. The source becomes `:class_annotation`, because the distribution is the
      # fact the diagnostic has to explain.
      def rebind(key)
        with(owner_key: key, source: :class_annotation)
      end
    end
  end
end
