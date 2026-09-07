# frozen_string_literal: true

require "digest"
require "json"

require_relative "../analysis/plugin_fact_fingerprint"
require_relative "../cache/descriptor"
require_relative "../cache/engine_source"
require_relative "../cache/file_digest"
require_relative "../cache/incremental_snapshot"
require_relative "../cache/store"
require_relative "../version"
require_relative "mutation_scanner"

module Rigor
  module Protection
    # Issue #134 slice 2 — the per-file cache for an ADR-63 Tier 2 measurement.
    #
    # A whole-project `rigor coverage --protection --mutation` run is `Σ(1 + N_f)` single-file analyses (the
    # investigation on #134: ≈94% of the wall time, and rising with the target set). Every one of them is
    # recomputed on every invocation, including for files nobody has touched since the last run. This stores
    # one {MutationScanner::FileResult} per file and serves it back when nothing it could depend on moved.
    #
    # ## What "nothing moved" means — the cache key
    #
    # The KEY carries the inputs that are known before the measurement and are not files:
    #
    # - `Rigor::VERSION` + this class's {SCHEMA} + the {Cache::Descriptor} schema — an engine upgrade is an ABI
    #   boundary for a Marshal'd `FileResult` and a measurement-semantics boundary for everything else. A
    #   VERSION pins the engine's bytes only for a RELEASED gem, so a checkout adds {Cache::EngineSource}'s
    #   source digest alongside it (#285) — without it, editing the analyzer and re-measuring serves the
    #   pre-edit kill counts back, which is the exact failure a mutation score exists to detect.
    # - The {Cache::IncrementalSnapshot} fingerprint the dependency edges came from — itself a digest of the
    #   resolved configuration, the analysis roots, `Gemfile.lock`, `rbs_collection.lock.yaml`, and the
    #   project's own `sig/` contents. This is how a config or `sig/` edit invalidates the measurement. Since
    #   #289 that fingerprint carries the engine-source digest too, which makes the slot above redundant on
    #   paper — keep it anyway: this key states its own soundness rather than inheriting it from how another
    #   cache happens to compose its key today, and a memoised digest costs nothing to repeat.
    # - `--limit` / `--seed` / the site selector: the report is already an estimate under a sample, and without
    #   them a `--limit 20` run would silently serve a `--limit 5` result.
    # - The sorted set of ADOPTED bleeding-edge feature ids that change this measurement (#255's principle: a
    #   behaviour feature's id enters the cache identity of everything it changes). `discovery-seeded-mutation-
    #   sites` moves both the denominator and the kills; `dependent-closure-kill-oracle` moves the kills — and
    #   that one additionally BYPASSES this cache entirely (see below).
    # - The whole-project ProjectScan tables (`synthetic_method_index`, `project_patched_methods`) by CONTENT
    #   DIGEST, plus the ADR-88 plugin fact-surface digest. Any file may contribute a row to those tables, so
    #   they go in by table diff, never by edge attribution — the same shape and the same reason as ADR-67
    #   WD6c's `param_seed_invalidation`.
    # - When the discovery seed is active, the seed's identity (see {.seed_digest}).
    #
    # The per-file FILE dependencies ride the ADR-45 record-and-validate side instead: the entry stores a
    # {Cache::Descriptor} of the measured file plus every `deps[A]` edge the ADR-46 snapshot recorded for it,
    # and {Cache::Store#peek_validated} re-validates them against the filesystem on the next run. `deps[A]` was
    # recorded during a full `check` run with cross-file discovery ON, while the Tier-2 oracle re-analyses the
    # mutant with discovery OFF (or seeded — see the seed slot above), so the recorded set is a strict SUPERSET
    # of what the oracle reads: over-invalidating, never under.
    #
    # ## Degradation — never a silent hit
    #
    # The cache disables itself, wholesale, when it cannot prove that much: no reusable snapshot (nobody has
    # run `rigor check --incremental` for this project / these roots), a plugin with no incremental fingerprint
    # surface (ADR-88's opaque case), tables it cannot digest, or `--no-cache`. Per file, a path the snapshot
    # never analysed has no `deps[A]` entry, which means "depends on every project file" — a miss for that file
    # alone. Every degradation is reported on stderr by the caller, because a measurement that quietly stopped
    # caching and a measurement that quietly served a stale number look identical from the outside.
    #
    # `dependent-closure-kill-oracle` (#254) bypasses the cache rather than keying on it: under that oracle a
    # file's verdict depends on the diagnostics of its DEPENDENTS, so validity would need the dependencies of
    # every dependent — a strictly wider edge set than `deps[A]`. The feature is presumptively non-graduating
    # (#254's closing comments), so a permanent bypass is the honest answer, not the key complexity.
    class MutationCache
      # Bumped when the stored value's shape or the key's composition changes, so entries written by an older
      # Rigor read as misses rather than as a differently-meant number.
      SCHEMA = 1

      PRODUCER_ID = "protection.mutation-file-result"

      # One live entry per (file, key) at once — the per-file producer shape, so the {Cache::Store#evict!}
      # generation pass leaves it alone and only the size-based LRU pass can touch it.
      GENERATION_CAP = Cache::Store::UNBOUNDED_GENERATIONS

      # The sampling knobs that make one measurement incomparable with another (see the class doc).
      Sampling = Data.define(:limit, :seed, :site_selector)

      # Human-readable reasons the caller prints. Each names something the operator can act on.
      NO_SNAPSHOT = "no reusable `rigor check --incremental` snapshot"
      OPAQUE_PLUGIN = "a plugin contributes types with no incremental fingerprint surface"
      UNDIGESTIBLE = "the project-scan tables could not be digested"
      UNIDENTIFIED_ENGINE = "the engine's own source tree could not be digested"

      class << self
        # @rbs roots: Array[String] --
        #   The analysis roots to look for a snapshot under, most-specific first (the command's own path arguments,
        #   then the configured `paths:`).
        # @rbs project_scan: Rigor::Analysis::ProjectScan -- The prepared whole-project scan.
        # @rbs feature_ids: Array[String] -- The ADOPTED bleeding-edge ids that change this measurement.
        # @rbs seed_inputs: Array[String]? --
        #   The files the {DiscoverySeed} was built over when it is active, nil when it is not. The CLI stays the only
        #   place that knows a feature id exists.
        # @rbs bypass_reason: String? --
        #   A caller-side reason to run uncached (`--no-cache`, the closure oracle). Reported verbatim.
        # @rbs return: MutationCache -- Enabled, or a disabled instance carrying `#reason`.
        def build(configuration:, roots:, project_scan:, sampling:, feature_ids:, seed_inputs: nil,
                  bypass_reason: nil)
          return disabled(bypass_reason) if bypass_reason
          return disabled(UNIDENTIFIED_ENGINE) unless engine_identifiable?

          matched = load_snapshot(configuration: configuration, roots: roots)
          return disabled(NO_SNAPSHOT) if matched.nil?

          fingerprint, payload = matched
          configs = key_configs(fingerprint: fingerprint, project_scan: project_scan, sampling: sampling,
                                feature_ids: feature_ids, seed_inputs: seed_inputs)
          return disabled(configs) if configs.is_a?(String)

          new(store: build_store(configuration), sources: payload.sources, key_configs: configs)
        end

        def disabled(reason)
          new(store: nil, sources: {}, key_configs: [], reason: reason)
        end

        def build_store(configuration)
          Cache::Store.new(root: configuration.cache_path, max_bytes: configuration.cache_max_bytes)
        end

        # The `[fingerprint, payload]` of the on-disk ADR-46 snapshot under any plausible root set, or nil.
        #
        # A snapshot is keyed to the ROOTS its writing run was invoked with, and a measurement has no way to
        # know which form that was: `rigor check --incremental lib` records `["lib"]`, a bare `rigor check
        # --incremental` records the configured `paths:` (absolute), and a measurement of a SUBDIRECTORY
        # shares neither. All four renderings are offered, one blob read (see {IncrementalSnapshot#load_any}).
        #
        # Accepting a snapshot whose roots differ from the measured paths is sound rather than lax: the
        # snapshot contributes per-file dependency edges only, and a file it never analysed simply has no
        # entry — which this cache already treats as a miss for that file.
        def load_snapshot(configuration:, roots:)
          candidates = snapshot_root_candidates(roots, configuration.paths).map do |candidate|
            Cache::IncrementalSnapshot.fingerprint(configuration: configuration, roots: candidate)
          end
          Cache::IncrementalSnapshot.new(root: configuration.cache_path).load_any(fingerprints: candidates)
        end

        def snapshot_root_candidates(roots, configured)
          [roots, Array(roots).map { |path| File.expand_path(path) },
           configured, Array(configured).map { |path| relative_to_pwd(path) }]
            .compact.reject(&:empty?).uniq
        end

        # `path` rendered relative to the working directory when it lies underneath it; unchanged otherwise.
        # Shared by the root-candidate list and the per-file snapshot lookup, which face the same skew.
        def relative_to_pwd(path)
          absolute = File.expand_path(path)
          prefix = "#{File.expand_path(Dir.pwd)}#{File::SEPARATOR}"
          absolute.start_with?(prefix) ? absolute.delete_prefix(prefix) : path.to_s
        end

        # The shared (path-independent) key slots, or a String reason when an input cannot be digested.
        def key_configs(fingerprint:, project_scan:, sampling:, feature_ids:, seed_inputs:)
          facts = Analysis::PluginFactFingerprint.key_digest(project_scan.plugin_registry)
          return OPAQUE_PLUGIN if facts.nil?

          tables = table_digest(project_scan)
          return UNDIGESTIBLE if tables.nil?

          (engine_source_entries + [
            config_entry("engine", "#{Rigor::VERSION}:#{SCHEMA}:#{Cache::Descriptor::SCHEMA_VERSION}"),
            config_entry("snapshot", fingerprint),
            config_entry("sampling", sampling.to_h.sort.map { |k, v| "#{k}=#{v.inspect}" }.join(" ")),
            config_entry("bleeding-edge", feature_ids.map(&:to_s).sort.join(",")),
            config_entry("project-tables", tables),
            config_entry("plugin-facts", facts),
            config_entry("discovery-seed", seed_digest(seed_inputs))
          ]).freeze
        rescue Cache::EngineSource::Unavailable
          UNIDENTIFIED_ENGINE
        rescue StandardError
          UNDIGESTIBLE
        end

        # Issue #285 — one extra slot pinning the ENGINE'S OWN SOURCE when `Rigor::VERSION` does not (a
        # checkout rather than a released gem). Empty for a released install, so its key composition is
        # unchanged and {SCHEMA} needs no bump; an engine that cannot be identified raises through to the
        # `Unavailable` rescue above and disables the cache, which is the only sound reading of a key slot
        # that could not be computed.
        def engine_source_entries
          identity = Cache::EngineSource.process_identity
          identity.nil? ? [] : [config_entry("engine-source", identity)]
        end

        # Probed BEFORE the snapshot load, for the reason string rather than for soundness. Since #289
        # {Cache::IncrementalSnapshot.fingerprint} folds the same digest in and answers a bare nil when it
        # cannot, so an unidentifiable engine already reaches the user as a disabled cache — but as
        # {NO_SNAPSHOT}, which tells them to run `rigor check --incremental`, a fix for a different problem.
        # The {Cache::EngineSource::Unavailable} rescue in {key_configs} stays as the backstop for a tree
        # that becomes unreadable between here and there.
        def engine_identifiable?
          Cache::EngineSource.process_identity
          true
        rescue Cache::EngineSource::Unavailable
          false
        end

        def config_entry(key, payload)
          Cache::Descriptor::ConfigEntry.new(key: key, value_hash: Digest::SHA256.hexdigest(payload))
        end

        # A stable content digest of the two whole-project pre-pass tables, over their own plain-data
        # renderings. `nil` when either declines to render (→ the cache disables itself rather than key on a
        # table it cannot see).
        def table_digest(project_scan)
          payload = {
            "synthetic" => project_scan.synthetic_method_index.to_h,
            "patched" => patched_rows(project_scan.project_patched_methods)
          }
          Digest::SHA256.hexdigest(JSON.generate(payload))
        rescue StandardError
          nil
        end

        # `ProjectPatchedMethods` has no plain-data rendering of its own; each row is flattened here, with the
        # recorded return type reduced to its short description (the value is a live `Rigor::Type`).
        def patched_rows(patched)
          patched.by_key.map do |(class_name, method_name, kind), entry|
            [class_name.to_s, method_name.to_s, kind.to_s, entry.source_path.to_s, entry.source_line,
             entry.return_type&.describe(:short).to_s]
          end.sort
        end

        # The identity of the cross-file {DiscoverySeed}, as the digest of its INPUTS: the sorted
        # `(path, content digest)` rows of the files it spans. The seed is a deterministic function of those
        # contents and of inputs already in the key (the resolved configuration and the plugin fact surface,
        # which fix the environment the parameter-inference pre-pass runs under), so hashing the inputs is at
        # least as strong an invalidation signal as hashing the built tables would be — and it never has to
        # traverse `discovered_def_nodes`, whose values are live `Prism::Node`s with no stable identity.
        #
        # Because the seed spans the whole measured path set, ANY measured file's edit invalidates EVERY
        # file's entry while the feature is adopted. That is the correct reading of "the seed is an input to
        # every file's measurement", not a defect of this digest.
        def seed_digest(seed_inputs)
          return "off" if seed_inputs.nil?

          digest = Digest::SHA256.new
          seed_inputs.sort.each { |path| digest << path << "\0" << Cache::FileDigest.hexdigest(path) << "\0" }
          digest.hexdigest
        end
      end

      def initialize(store:, sources:, key_configs:, reason: nil)
        @store = store
        @sources = sources
        @key_configs = key_configs
        @reason = reason
        @hits = 0
        @misses = 0
        @snapshot_keys = {}
      end

      attr_reader :reason, :hits, :misses

      def enabled?
        @reason.nil?
      end

      # The cached result for `path`, or nil on any miss (including "this cache is disabled").
      # @rbs return: MutationScanner::FileResult?
      def fetch(path)
        return nil unless enabled?
        # A path the snapshot never analysed has no recorded `deps[A]`, which means "depends on every project
        # file". Answering that from the key alone keeps the read path free of the digesting the WRITE path
        # does — the stored entry's own dependency descriptor is what a hit is validated against.
        return miss if snapshot_key(path).nil?

        value = @store.peek_validated(producer_id: PRODUCER_ID, key_descriptor: key_descriptor,
                                      params: params_for(path))
        return miss unless value.is_a?(MutationScanner::FileResult)

        @hits += 1
        value
      rescue StandardError
        miss
      end

      # Persist one measured file. Returns false when nothing was written.
      #
      # A result carrying `harness_errors` (#264 — mutants that blew up INSIDE the measurement harness) is
      # never persisted: that run measured the harness rather than the code, and freezing it into a warm hit
      # would make a transient failure permanent and invisible.
      def store(path, result)
        return false unless enabled?
        return false unless result.is_a?(MutationScanner::FileResult)
        return false if result.harness_errors.positive?

        dependency = dependencies(path)
        return false if dependency.nil?

        @store.fetch_or_validate(producer_id: PRODUCER_ID, key_descriptor: key_descriptor,
                                 params: params_for(path), generation_cap: GENERATION_CAP) do
          [result, dependency]
        end
        true
      rescue StandardError
        false
      end

      private

      def miss
        @misses += 1
        nil
      end

      # The record-and-validate dependency descriptor for `path`: the file itself plus every `deps[path]` edge
      # the snapshot recorded. nil when the snapshot never analysed the file (→ "depends on every project
      # file", the degradation this cache refuses to guess at) or a recorded file has since vanished.
      def dependencies(path)
        key = snapshot_key(path)
        sources = key && @sources[key]
        return nil if sources.nil?

        entries = ([key] + sources.to_a).uniq.map do |dependency|
          Cache::Descriptor::FileEntry.stat(path: dependency, digest: Cache::FileDigest.hexdigest(dependency))
        end
        Cache::Descriptor.new(files: entries)
      rescue StandardError
        nil
      end

      # The snapshot records project-relative paths; a measurement may have been invoked with an absolute one.
      def snapshot_key(path)
        @snapshot_keys.fetch(path) do
          @snapshot_keys[path] =
            if @sources.key?(path)
              path
            else
              relative = relative_to_pwd(path)
              @sources.key?(relative) ? relative : nil
            end
        end
      end

      def relative_to_pwd(path)
        self.class.relative_to_pwd(path)
      end

      def key_descriptor
        @key_descriptor ||= Cache::Descriptor.new(configs: @key_configs)
      end

      def params_for(path)
        { "path" => snapshot_key(path) || path }
      end
    end
  end
end
