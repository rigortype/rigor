# frozen_string_literal: true

require_relative "../effects/label_set"
require_relative "../effects/method_key"
require_relative "../effects/summary"

module Rigor
  module SigGen
    # ADR-103 WD9 / ADR-14's reserved annotation-emission slot — decides whether a generated signature
    # carries `%a{pure}` or `%a{rigor:v1:effect …}`, and records WHY when it does not.
    #
    # The whole module is one decision applied per method, and every branch of it exists to keep a WRONG
    # annotation off the page. An emitted annotation is not a hint: the effects opt-in reads it back as an
    # envelope and enforces it on the method and on everything the method reaches, so a `%a{pure}` sig-gen
    # invented is a false contract that manufactures `effect.envelope-exceeded` on correct code. That is why
    # the gates below are all one-directional — each of them can only suppress an emission.
    #
    # The gates, in order:
    #
    # 1. **No summary** — the method is not an effect unit this run collected. Nothing is emitted and nothing
    #    is reported: the absence is about the run, not about the method.
    # 2. **Non-exhaustive** ({Effects::Summary#exhaustive?} false) — the summary reads "these effects, and
    #    possibly more", which is precisely the claim an envelope must not make. `withheld-non-exhaustive`.
    # 3. **Policy-discharged** — the transitive proven lane and the `effects.tolerated:` judgment disagree,
    #    so some part of this method's footprint is only invisible because the project agreed to ignore it.
    #    `docs/type-specification/effect-labels.md` § Discharge by policy, invariant 4 ("emission uses
    #    undischarged sets") and ADR-10 WD7's "opportunistic shapes never round-trip" are the same rule:
    #    a tolerated `telemetry` origin does not earn a written `%a{pure}`. `withheld-tolerated`.
    # 4. **Unclaimed callee** ({Effects::EffectTable::Entry#unclaimed?}) — the method, or something it
    #    reaches, called something NOTHING described: no catalogue row, no plugin row, no envelope, and no
    #    project definition the closure could read. The summary is exhaustive, because every call
    #    RESOLVED — but "every call resolved" and "every callee's footprint is known" are different
    #    questions, and only the second one licenses a written bound. `withheld-unclaimed-callee`.
    # 5. **A surviving declared label** ({Effects::EffectTable::Entry#trivial?}) — the proven lane is empty
    #    and the `≤` lane is not, which is a method whose callee stated a bound the analyzer never proved
    #    away. `%a{pure}` there would contradict a claim the project already carries.
    #    `withheld-declared`.
    # 6. **Proven pure** — exhaustive, undischarged, claimed, and nothing outside `{mutate.local}` in
    #    either lane. `%a{pure}`, the ecosystem's existing purity spelling (design § 6.3), which hands
    #    Steep users better narrowing.
    # 7. **Proven effectful** — the same, with real labels. `%a{rigor:v1:effect …}` only when the caller
    #    asked for envelopes; otherwise nothing, because the labelled spelling is Rigor's own and writing
    #    it into a project's `sig/` unbidden is a bigger commitment than a purity tag.
    module EffectAnnotation
      # The `sig.*` telemetry identifiers for this emission, alongside {Classification::DIAGNOSTIC_IDS} and
      # {Classification::SKIP_DIAGNOSTIC_IDS}. Documented in `docs/type-specification/diagnostic-policy.md`
      # and `docs/handbook/11-sig-gen.md` with the rest of the `sig.*` family.
      DIAGNOSTIC_IDS = {
        # An annotation was rendered onto the proposal.
        emitted: "sig.effect.emitted",
        # Withheld: the proven footprint and the `effects.tolerated:` judgment disagree.
        withheld_tolerated: "sig.effect.withheld-tolerated",
        # Withheld: some call this method reaches could not be resolved.
        withheld_non_exhaustive: "sig.effect.withheld-non-exhaustive",
        # Withheld: some call it reaches resolved, and nothing anywhere says what that callee does.
        withheld_unclaimed_callee: "sig.effect.withheld-unclaimed-callee",
        # Withheld: the `≤` lane carries a label the proven lane does not already admit.
        withheld_declared: "sig.effect.withheld-declared",
        # Write-time: the target declaration already carries annotations, so its bytes were left alone.
        left_unreadable: "sig.effect.left-unreadable"
      }.freeze

      module_function

      # The effect-unit key for a sig-gen candidate, in {Effects::MethodKey}'s spelling.
      def key_for(class_name, method_name, kind)
        return nil if class_name.nil?

        "#{class_name}#{kind == :singleton ? '.' : '#'}#{method_name}"
      end

      # Turns one {Effects::EffectTable::Entry} into the annotation lines to render and the reason to report.
      #
      # @return `[Array<String> annotations, Symbol|nil reason]`. An empty
      #   array with a `nil` reason is "nothing to say about this method".
      def decide(entry, envelopes: false)
        return [[], nil] if entry.nil?
        return [[], :withheld_non_exhaustive] unless entry.exhaustive?
        return [[], :withheld_tolerated] unless entry.proven == entry.undischarged
        return [[], :withheld_unclaimed_callee] if entry.unclaimed?
        # `trivial?` is the report's own "nothing to say about this method" test, and it is the emission
        # test too: exhaustive, nothing beyond `mutate.local` proven, and NOTHING SURVIVING in the `≤`
        # lane. The last conjunct is what a bare `proven.subsumed_by?` misses — a callee's imported
        # envelope lands in the declared lane with no taint and no proven label, so a method whose whole
        # body is one `Remote.fetch` reads `[] ≤ [io.net.http]` while proving nothing at all.
        return [["%a{pure}"], :emitted] if entry.trivial?
        return [[], :withheld_declared] if entry.proven.subsumed_by?(Effects::Summary::TRIVIAL_BOUND)
        return [[], nil] unless envelopes
        # A surviving declared label is not spelled either. The envelope grammar carries ONE bound per
        # declaration and has no way to say "proves this, claims that", so writing the proven set alone
        # would publish a bound narrower than the claim the project already carries.
        return [[], :withheld_declared] unless entry.rendered_declared.empty?
        # `top?` is the unbounded reading: it names no labels, so there is no envelope to spell.
        return [[], nil] if entry.proven.top? || entry.proven.empty?

        [["%a{rigor:v1:effect #{entry.proven.to_a.join(', ')}}"], :emitted]
      end

      # Per-run lookup over an {Effects::EffectTable}. Built by the CLI when the project's `effects:` opt-in
      # is on, and `nil` otherwise — which is what makes effects-off output byte-identical to a run before
      # this feature existed.
      class Annotator
        def initialize(table:, envelopes: false)
          @table = table
          @envelopes = envelopes
          freeze
        end

        # @return `[Array<String>, Symbol|nil]` — see {EffectAnnotation.decide}.
        def annotate(class_name:, method_name:, kind:)
          key = EffectAnnotation.key_for(class_name, method_name, kind)
          return [[], nil] if key.nil?

          EffectAnnotation.decide(@table[key], envelopes: @envelopes)
        end
      end
    end
  end
end
