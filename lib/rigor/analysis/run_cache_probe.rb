# frozen_string_literal: true

require_relative "result"
require_relative "run_cache_key"
require_relative "path_expansion"
require_relative "severity_stamp"
require_relative "runner/effect_annotation_residual_pass"
require_relative "../cache/store"
require_relative "../cache/file_digest"
require_relative "../effects/signature_sources"

module Rigor
  module Analysis
    # ADR-87 WD4 — the boot-slimming run-cache hit probe. Serves an ordinary `rigor check`'s diagnostics
    # straight from the ADR-45 `analysis.run-diagnostics` cache WITHOUT loading the inference engine, its
    # plugin gems, or building the RBS environment: a warm HIT boots only CLI + config + cache + digest code
    # (the recon's `$LOADED_FEATURES` never gains a `rigor/inference` entry). The full plugin/prepass +
    # env-build tax (~0.8s on a gitlab null) is paid ONLY on a miss.
    #
    # Soundness is inherited wholesale from ADR-45: the stored dependency descriptor records every file the
    # prior run read — analyzed sources, the RBS signature tree, AND every file each plugin read mid-analysis
    # (the Pundit-policy case) — and {Cache::Store#peek_validated} re-checks all of it against the live tree
    # (ADR-87 `:stat`-validated). A hit therefore means every input the prior run observed is unchanged, so
    # its cached diagnostics are exactly what a fresh full run would produce; skipping the plugin prepasses is
    # sound because their inputs are in that same validated set. The key is built through the shared
    # {RunCacheKey} — a project whose plugins synthesise virtual RBS produces a probe key that omits that
    # entry, so it simply misses and the full path takes over (never a wrong hit).
    #
    # ## What the slot does NOT contain (#428)
    #
    # ADR-103 puts the two effect diagnostics OUTSIDE the cached run assembly on purpose: the `effects:`
    # block is deliberately absent from the diagnostics cache identity, so a finding written into that
    # entry would outlive the configuration that produced it. `Runner#run_analysis` therefore appends them
    # after `#compute_run_diagnostics` — which is exactly the code a served hit skips. Serving the slot
    # verbatim silently dropped both of them on every warm run, and a check that only ever fires on a cold
    # cache is worse than one that never fires at all.
    #
    # A probe that serves a slot has to answer for what the slot omits, so this one does, per pass:
    #
    # - `effect.annotations-unchecked` is **reproduced here**. It was built to be free (a glob and a regex
    #   over the project's own signature tree — {Effects::SignatureSources}), so the probe simply runs it,
    #   with no loader: the inline stratum is the documented fail-quiet direction of that pass, and it is
    #   the stratum a run without an environment never had.
    # - `effect.envelope-exceeded` / `effect.liskov-widened` / `effect.unknown-label` cannot be: they read
    #   the propagated effect graph and the cross-file discovery tables, i.e. the engine this path exists
    #   to skip. So the probe **declines** for a project that could earn one ({#envelope_lane_live?}) and
    #   the full path — which caches both halves in its own two slots, and re-judges them every run —
    #   serves it instead. The decline is measured against the declarations alone, never against what they
    #   would judge to, so it costs one glob and never a wrong answer.
    class RunCacheProbe
      # @param configuration [Rigor::Configuration]
      # @param cache_root [String]
      # @param explain [Boolean] the `--explain` flag (folded into the key, as the runner does).
      def initialize(configuration:, cache_root:, explain:)
        @configuration = configuration
        @cache_root = cache_root
        @explain = explain
      end

      # @param paths [Array<String>] the analysis roots (`@argv` or `configuration.paths`).
      # @return [Analysis::Result, nil] the cached run result with the severity profile applied and no stats
      #   (matching a cache-served `Runner#run`), or nil to DECLINE — a miss / stale / unavailable cache — so
      #   the caller loads the engine and runs the full path. Any failure declines rather than raising: the
      #   probe must never turn a servable run into a crash.
      def serve(paths)
        files = PathExpansion.ruby_files(paths, @configuration.exclude_patterns)
        key = RunCacheKey.descriptor(
          configuration: @configuration, files: files, explain: @explain,
          rbs_config_entries: RunCacheKey.libraries_config_entries(@configuration)
        )
        return nil if key.nil?

        diagnostics = validated_diagnostics(key)
        return nil if diagnostics.nil?
        # #428 — asked only after the peek, so a run that was going to miss anyway never pays the walk.
        return nil if envelope_lane_live?

        Result.new(
          diagnostics: SeverityStamp.apply(diagnostics + residual_diagnostics, @configuration), stats: nil
        )
      rescue StandardError
        nil
      end

      private

      # #428 — whether this project could earn one of the three diagnostics {Runner::EffectEnvelopePass}
      # produces, which are the ones no cached slot carries and no engine-free path can recompute.
      #
      # Read off the DECLARATIONS, because a declaration is the whole of what the engine-free side can
      # see: the four `.rigor.yml` policy lists, and whether the project's own signature tree carries an
      # effect annotation at all ({Effects::SignatureSources::ANNOTATION_HINT}, the same one-regex-per-file
      # pre-filter the envelope reader routes on). Over-declining is free — it forgoes a fast lane for a
      # run the full path still serves out of the same two warm slots — while under-declining is the bug
      # this method exists for, so anything ambiguous answers true.
      def envelope_lane_live?
        return false unless @configuration.effects_check?

        declared_in_config? || !Effects::SignatureSources.first_annotated(signature_sources).nil?
      end

      # The `effects:` policy surface an `effect.unknown-label` can be read off, plus the envelopes an
      # `effect.envelope-exceeded` / `effect.liskov-widened` is judged against. A project that opted into
      # effects and declared none of them has nothing for the pass to say.
      def declared_in_config?
        !@configuration.effects_envelopes.empty? || !@configuration.effects_tolerated.empty? ||
          !@configuration.effects_labels.empty? || !@configuration.effects_attribution.empty?
      end

      # `effect.annotations-unchecked`, reproduced verbatim — the pass self-gates on `effects_enabled?`,
      # so exactly one of it and {#envelope_lane_live?} is ever non-empty, as on the full path.
      def residual_diagnostics
        Runner::EffectAnnotationResidualPass.new(configuration: @configuration).diagnostics
      end

      # One walk, whichever of the two lanes asks: the residual pass collects its own (it is the one that
      # runs when effects are off), so the memo only ever serves the envelope-lane decline.
      def signature_sources
        @signature_sources ||= Effects::SignatureSources.collect(
          signature_paths: @configuration.signature_paths
        )
      end

      def validated_diagnostics(key)
        store = Cache::Store.new(root: @cache_root, max_bytes: @configuration.cache_max_bytes)
        # The digest fallback + `cache.validation` / RIGOR_STRICT_VALIDATION escape hatch route through the
        # same per-run FileDigest scope the full run uses.
        strict = @configuration.cache_validation_strict?
        Cache::FileDigest.with_run(strict: strict) do
          store.peek_validated(
            producer_id: RunCacheKey::RUN_DIAGNOSTICS_PRODUCER_ID, key_descriptor: key
          )
        end
      end
    end
  end
end
