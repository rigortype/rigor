# frozen_string_literal: true

require_relative "result"
require_relative "run_cache_key"
require_relative "path_expansion"
require_relative "severity_stamp"
require_relative "../cache/store"
require_relative "../cache/file_digest"

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

        Result.new(diagnostics: SeverityStamp.apply(diagnostics, @configuration), stats: nil)
      rescue StandardError
        nil
      end

      private

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
