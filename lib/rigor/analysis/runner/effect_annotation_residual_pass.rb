# frozen_string_literal: true

require_relative "../diagnostic"
# ADR-87 WD4 — the pure-data rule-id table, never the engine-heavy `check_rules.rb` that reopens the
# same module. This pass is one of the two the boot-slimming {Analysis::RunCacheProbe} has to run for
# itself on a cache hit (#428), and requiring the full rule set would put `rigor/inference` back into
# a hit's `$LOADED_FEATURES`.
require_relative "../check_rules/rule_ids"
require_relative "../../effects/inline_anchor"
require_relative "../../effects/signature_sources"

module Rigor
  module Analysis
    class Runner
      # `effect.annotations-unchecked` — the ADR-103 WD13 commitment-1 residual (#384).
      #
      # WD13 fixes two rules that pull against each other: an annotation **must not** turn effect
      # collection on (a `%a{pure}` written for Steep's benefit would otherwise impose a project-wide
      # cost cliff on every run of every project that has one), and an annotation **must not** be
      # silently inert either. One `:info` per run is the whole reconciliation: the declarations are
      # there, nothing reads them, and `effects: {}` is the one-line answer.
      #
      # ## What it is allowed to cost
      #
      # This runs on the surface that is meant to be free — a project with no `effects:` block, which
      # is every project by default — so the budget is a glob and a regex:
      #
      # - It reads the project's own `signature_paths:` `.rbs` tree (the same stratum the envelope
      #   check reads) and matches {Effects::SignatureSources::ANNOTATION_HINT} line by line. No RBS
      #   parse, no analysis, no environment build, and nothing at all when the tree does not exist.
      # - It consults the run's virtual RBS — rbs-inline's `# @rbs %a{…}` — only when the run ALREADY
      #   resolved an environment. Building one here to find an `:info` would cost more than the
      #   `:info` is worth, so the pass never reaches for a loader; every caller hands it what the run
      #   had. #441 is why the caller side matters: an ANALYZING run always has an environment, so the
      #   stratum is carried out of the analysis path as
      #   {Runner::RunSnapshots#effect_annotation_carrier} whatever its mode, and the two lanes of
      #   chapter 16 report the same annotation. The one shape that genuinely has no environment is a
      #   warm ADR-87 WD4 cache hit served by {Analysis::RunCacheProbe} — an engine-free path whose
      #   whole point is not building one — so there, and only there, an inline-only annotation goes
      #   unreported. Under-reporting is the fail-quiet direction; the check itself never depends on
      #   this pass.
      #
      # It is computed OUTSIDE the cached run assembly for the same reason `EffectEnvelopePass` is:
      # the `effects:` block is deliberately absent from the diagnostics cache identity, so a residual
      # baked into that entry would survive the very edit that answers it.
      class EffectAnnotationResidualPass
        NO_DIAGNOSTICS = [].freeze
        private_constant :NO_DIAGNOSTICS

        RULE = CheckRules::RULE_EFFECT_ANNOTATIONS_UNCHECKED

        MESSAGE = "Effect annotations (`%a{pure}` / `%a{rigor:v1:effect …}`) are present in your " \
                  "project's signatures, but `.rigor.yml` carries no `effects:` block, so effect " \
                  "collection never runs and nothing checks them — they are documentation, not a " \
                  "contract. Add `effects: {}` to have Rigor prove what your methods do and check " \
                  "these bounds against it (ADR-103); an annotation alone never turns collection " \
                  "on, because that would make one line in one signature file more expensive for " \
                  "every run of the project."
        private_constant :MESSAGE

        # @param configuration [Rigor::Configuration]
        # @param virtual_rbs [Array<Array(String, String)>, nil] `[buffer name, RBS source]` pairs the
        #   run ALREADY resolved; never a loader built for this pass. Empty / nil simply drops the
        #   virtual-RBS stratum.
        def initialize(configuration:, virtual_rbs: nil)
          @configuration = configuration
          @virtual_rbs = virtual_rbs
        end

        # @return [Array<Diagnostic>] zero or one.
        def diagnostics
          return NO_DIAGNOSTICS if @configuration.effects_enabled?
          return NO_DIAGNOSTICS if @configuration.disabled_rules.include?(RULE)

          sources = Effects::SignatureSources.collect(
            signature_paths: @configuration.signature_paths, virtual_rbs: @virtual_rbs
          )
          return NO_DIAGNOSTICS if sources.empty?

          found = Effects::SignatureSources.first_annotated(sources)
          found.nil? ? NO_DIAGNOSTICS : [build_diagnostic(found)]
        rescue StandardError
          # Fail-soft, like every other effects surface: an advisory `:info` must never fail a run.
          NO_DIAGNOSTICS
        end

        private

        # Positioned at the first annotation itself rather than at `.rigor.yml:1`: the fix is a config
        # edit, but the thing being reported is something the author wrote, and pointing at it is what
        # tells them WHICH declaration is inert.
        #
        # A `virtual:` buffer's line numbers are the synthesized RBS's, not the `.rb`'s, so the position
        # is re-anchored onto the Ruby file the same way the envelope reader anchors a declaration
        # ({Effects::InlineAnchor}) — one mapping, so the advisory and the check can never name two
        # different lines for one annotation.
        def build_diagnostic(found)
          name, content, line = found
          path = Effects::SignatureSources.source_path(name)
          Diagnostic.new(
            path: path, line: Effects::InlineAnchor.ruby_line(path: path, buffer: content, buffer_line: line),
            column: 1, message: MESSAGE, severity: :info, rule: RULE, source_family: :builtin
          )
        end
      end
    end
  end
end
