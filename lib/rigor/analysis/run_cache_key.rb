# frozen_string_literal: true

require "digest"
# ADR-87 WD4 — the `rbs` gem's version feeds the cache key's `gems` slot (`RbsDescriptor.rbs_gem_entry`).
# Load only its version constant (not the full RBS parser / env) so the boot-slimming probe can build the key
# without paying for — or `$LOADED_FEATURES`-touching — the RBS machinery. Falls back to the full gem only if
# this build of `rbs` has no standalone version file.
begin
  require "rbs/version"
rescue LoadError
  require "rbs"
end

require_relative "../version"
require_relative "../cache/descriptor"
require_relative "../cache/engine_source"
require_relative "../cache/rbs_descriptor"
require_relative "../environment/default_libraries"

module Rigor
  module Analysis
    # ADR-45 / ADR-87 WD4 — the stable run-result cache KEY, built in ONE place so the miss path (the
    # {Analysis::Runner}) and the boot-slimming hit path (the {RunCacheProbe}) can never drift out of key
    # agreement. The key reads the stable inputs known before analysis: the `rbs` gem version, the resolved
    # RBS library list, a digest of the whole resolved configuration, the engine + schema + `--explain`
    # triple, and the analyzed-path SET.
    #
    # The ONLY difference between the two callers is the `rbs_config_entries` slot: the Runner passes the
    # loader's `RbsDescriptor.config_entries` (which include a `rbs.virtual_rbs` entry when a plugin's
    # `source_rbs_synthesizer` contributed one), while the probe passes {#libraries_config_entries} —
    # reconstructed from config alone, WITHOUT building the RBS environment or loading any plugin. A project
    # whose plugins DO synthesise virtual RBS therefore produces a probe key that omits that entry, so the
    # probe simply misses and the full path takes over (sound: never a wrong hit, only a forgone fast lane).
    # Slot order is irrelevant — {Cache::Descriptor#to_canonical_hash} sorts configs by key.
    module RunCacheKey
      module_function

      RUN_DIAGNOSTICS_PRODUCER_ID = "analysis.run-diagnostics"

      # ADR-103 WD13 / issue #382 — the whole-run **effects sidecar**: the run's per-file effect
      # collections, keyed by {Effects::Identity.descriptor} (this key descriptor plus the vocabulary
      # version, the catalogue identity and the `effects:` digest) rather than by the descriptor above.
      #
      # A separate producer id, not a second section of the diagnostics entry, and that is the whole of
      # "the diagnostics slot is never invalidated by effects": the two slots cannot share a fate when they
      # do not share a file. It also keeps the ADR-87 boot-slim probe reading exactly the bytes it reads
      # today — it peeks `analysis.run-diagnostics` and finds a plain diagnostics array, whatever a
      # collecting run wrote elsewhere.
      RUN_EFFECTS_PRODUCER_ID = "analysis.run-effects"

      # The run-result producer's declared compaction budget (`Cache::Store#evict!` pass 2). Whole-project,
      # but unlike the `rbs.*` producers several generations can be live at once: the `paths` key slot means
      # one entry per analyzed-path SET, so `rigor check` over the whole project, over `lib`, and over a
      # single file are three separate live generations. 16 is a judgement call sized for that churn; it is
      # a cap on GENERATIONS, not on correctness — over-evicting here costs a recompute, never a wrong
      # answer. Measured 2026-07-25 against a real project's `.rigor/cache`: the cap does bind (60 distinct
      # path-set generations observed, differing in the `paths` slot alone), with no evidence yet on how
      # often an evicted generation is asked for again — see issue #151.
      GENERATION_CAP = 16

      # The effects sidecar's own compaction budget. One generation per (path set × effects identity), and
      # only a project that opted in writes any at all, so it is sized as the diagnostics cap's shadow: a
      # collecting project's path-set churn is the same churn, and over-evicting costs one recompute.
      EFFECTS_GENERATION_CAP = GENERATION_CAP

      # @param rbs_config_entries [Array<Cache::Descriptor::ConfigEntry>] the RBS-derived config slots
      #   (`rbs.libraries` [+ `rbs.virtual_rbs`]). nil on any failure so a malformed key disables the cache.
      def descriptor(configuration:, files:, explain:, rbs_config_entries:)
        Cache::Descriptor.new(
          gems: [Cache::RbsDescriptor.rbs_gem_entry],
          configs: rbs_config_entries + engine_source_entries + [
            config_entry("configuration", Marshal.dump(configuration.to_h)),
            config_entry("engine",
                         "#{Rigor::VERSION}:#{Cache::Descriptor::SCHEMA_VERSION}:#{explain}"),
            config_entry("paths", files.sort.join("\n"))
          ]
        )
      rescue StandardError
        nil
      end

      # Issue #285 — the `engine` slot above pins the engine by VERSION, which identifies the source only
      # for a released gem. A checkout (a contributor's, or a `bundle add rigor, github:` clone) gets one
      # extra slot carrying a digest of the engine's own source, so editing `lib/rigor/inference/*.rb` no
      # longer replays the pre-edit diagnostics out of a warm cache. A released install adds NO entry, so
      # its key — and its hit rate — are exactly what they were.
      #
      # {Cache::EngineSource::Unavailable} is left to propagate into `descriptor`'s rescue, which disables
      # the cache for the run: an engine we cannot identify must not be keyed by its version alone.
      def engine_source_entries
        identity = Cache::EngineSource.process_identity
        return [] if identity.nil?

        [config_entry("engine-source", identity)]
      end

      def config_entry(key, payload)
        Cache::Descriptor::ConfigEntry.new(key: key, value_hash: Digest::SHA256.hexdigest(payload))
      end

      # The `rbs.libraries` config slot reconstructed from configuration alone — byte-identical to the
      # loader's `RbsDescriptor.libraries_entry(loader.libraries)` because `Environment.for_project` merges
      # exactly `DEFAULT_LIBRARIES + config.libraries` (uniq) into `loader.libraries`.
      def libraries_config_entries(configuration)
        merged = (Environment::DEFAULT_LIBRARIES + configuration.libraries.map(&:to_s)).uniq
        [Cache::RbsDescriptor.libraries_entry(merged)]
      end
    end
  end
end
