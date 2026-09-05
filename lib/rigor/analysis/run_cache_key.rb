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
require_relative "../cache/file_digest"
require_relative "../cache/rbs_descriptor"
require_relative "../environment/default_libraries"
# Both resolvers are leaf files (no requires beyond `yaml`), so the boot-slimming probe reaches the two
# lockfile paths without loading `rigor/environment` or the RBS machinery.
require_relative "../environment/lockfile_resolver"
require_relative "../environment/rbs_collection_discovery"

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

      # #482 — the **serving** half of the sidecar, under the same effects identity: the propagated table,
      # the unit sources and the merged as-written superclass table. Everything a warm run reads, and
      # nothing else.
      #
      # It is a separate entry rather than a section of {RUN_EFFECTS_PRODUCER_ID} because the collections
      # blob is large in exactly the projects where warm latency matters — 6.9 MB and 0.71 s of `Marshal`
      # on gitlab `app lib`, against ~40 KB here — and a warm run consumes none of it. The collections
      # entry stays, read lazily by the paths that genuinely need per-file form (an ADR-46 recheck, the
      # fail-soft re-propagation), so a consumer this split did not anticipate loads the blob rather than
      # seeing an empty table.
      RUN_EFFECTS_TABLE_PRODUCER_ID = "analysis.run-effects-table"

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

      # @rbs rbs_config_entries: Array[Cache::Descriptor::ConfigEntry] --
      #   The RBS-derived config slots (`rbs.libraries` [+ `rbs.virtual_rbs`]). nil on any failure so a malformed key
      #   disables the cache.
      def descriptor(configuration:, files:, explain:, rbs_config_entries:)
        Cache::Descriptor.new(
          gems: [Cache::RbsDescriptor.rbs_gem_entry],
          configs: rbs_config_entries + engine_source_entries + lockfile_entries(configuration) + [
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

      # Issue #564 — the two dependency lockfiles, BY CONTENT. Both are inputs to the run's diagnostics and
      # neither was represented in the key: the locked gem set decides which bundle-shipped `sig/` dirs and
      # which `rbs_collection` dirs load, which ADR-72 gem overlays apply, what the ADR-82 WD9 missing-gem
      # constant index owns, and whether `rbs.coverage.missing-gem` fires at all. Editing a lockfile touches
      # no analyzed source and no `.rbs` file, so the `paths` slot, the `configuration` slot (which carries
      # the lockfile PATH, never its bytes) and the recorded dependency descriptor were all unchanged by a
      # `bundle add` — and a warm run replayed the pre-edit diagnostics in BOTH directions: an
      # `undefined-method` on `3.minutes` surviving the `bundle add activesupport` that licenses the overlay,
      # and the same call staying silent after the `bundle remove` that revokes it.
      #
      # A KEY slot rather than a dependency entry, because a dependency descriptor can only say "a file I
      # recorded changed": it cannot express a lockfile that did not exist when the entry was written and
      # does now, which is the `bundle init` / first-`bundle install` case.
      #
      # Content-only — the resolved PATH is deliberately not in the payload, so a checkout that moves (a CI
      # runner's workspace, a renamed directory) still hits with an identical lockfile.
      def lockfile_entries(configuration)
        bundler = Environment::LockfileResolver.resolve_lockfile_path(
          lockfile_path: configuration.bundler_lockfile, auto_detect: configuration.bundler_auto_detect
        )
        collection = Environment::RbsCollectionDiscovery.resolve_lockfile_path(
          lockfile_path: configuration.rbs_collection_lockfile,
          auto_detect: configuration.rbs_collection_auto_detect
        )
        [lockfile_entry("bundler.lockfile", bundler), lockfile_entry("rbs_collection.lockfile", collection)]
      end

      # `nil` — no lockfile resolves — is itself part of the identity, so it carries its own sentinel rather
      # than dropping the slot: "absent" and "present but empty" must not key the same.
      ABSENT_LOCKFILE = "\0absent"

      def lockfile_entry(key, path)
        config_entry(key, path.nil? ? ABSENT_LOCKFILE : Cache::FileDigest.hexdigest(path.to_s))
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
