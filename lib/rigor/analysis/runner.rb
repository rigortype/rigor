# frozen_string_literal: true

require "digest"
require "prism"
require "tmpdir"

require_relative "../environment"
require_relative "../scope"
require_relative "../cache/store"
require_relative "../cache/rbs_descriptor"
require_relative "../cache/file_digest"
require_relative "run_cache_key"
require_relative "path_expansion"
require_relative "../plugin"
require_relative "../plugin/source_rbs_synthesis_reporter"
require_relative "../rbs_extended/reporter"
require_relative "../rbs_extended/conformance_checker"
require_relative "../reflection"
require_relative "../type/combinator"
require_relative "../inference/coverage_scanner"
require_relative "../effects/attribution"
require_relative "../effects/collector"
require_relative "../effects/envelope_index"
require_relative "../effects/identity"
require_relative "../effects/propagator"
require_relative "../inference/parameter_inference_collector"
require_relative "../inference/pre_eval_constants"
require_relative "../inference/scope_indexer"
require_relative "../inference/synthetic_method_scanner"
require_relative "../inference/project_patched_scanner"
require_relative "../inference/method_dispatcher/file_folding"
require_relative "buffer_binding"
require_relative "check_rules"
require_relative "dependency_recorder"
require_relative "self_call_resolution_recorder"
require_relative "incremental"
require_relative "incremental_session"
require_relative "dependency_source_inference"
require_relative "diagnostic"
require_relative "erb_template_detector"
require_relative "project_scan"
require_relative "result"
require_relative "run_stats"
require_relative "worker_session"
require_relative "runner/run_snapshots"
require_relative "runner/project_pre_passes"
require_relative "runner/pool_coordinator"
require_relative "runner/diagnostic_aggregator"
require_relative "runner/effect_envelope_pass"
require_relative "runner/effect_annotation_residual_pass"
require_relative "runner/buffer_pool_dispatcher"

module Rigor
  module Analysis
    class Runner # rubocop:disable Metrics/ClassLength
      DEFAULT_CACHE_ROOT = ".rigor/cache"

      # ADR-89 WD2 — bounds on the persisted return summaries (per-def observed call keys, and total defs
      # summarised) so the incremental snapshot stays small. A def observed under more keys than the per-def
      # cap keeps only the first; a def past the total cap is dropped (its symbol dependents then always
      # re-check — the conservative direction).
      RETURN_SUMMARY_KEYS_PER_DEF = 8
      RETURN_SUMMARY_TOTAL_CAP = 4000

      attr_reader :cache_store, :plugin_registry, :dependency_source_index,
                  :rbs_extended_reporter, :boundary_cross_reporter,
                  :analyzed_files, :unresolved_self_calls, :seed_bundles

      # ADR-46 — the per-file cross-file read records this run captured (empty unless
      # `record_dependencies: true`). Sequential analysis records into `@file_dependencies` via
      # {#analyze_file}; the fork pool records per-worker and marshals the records into the coordinator, so a
      # pooled `--incremental` recheck refreshes the same dependency graph a sequential recheck would. A run
      # is either sequential OR pooled for a given file set, so the two maps never carry the same key.
      def file_dependencies
        pooled = @pool_coordinator.collected_dependencies
        pooled.empty? ? @file_dependencies : @file_dependencies.merge(pooled)
      end

      # ADR-103 — the run's propagated effect graph, or {Effects::EffectTable.empty} when collection did
      # not run. Reconciled from the sequential and pooled halves exactly as {#file_dependencies} is, then
      # closed by the post-pool fixpoint in {#assemble_run_diagnostics}.
      #
      # This is a **report surface, not a diagnostic one**: nothing here enters the diagnostic stream, and
      # `rigor check`'s output is identical whether or not it was computed (ADR-102's line).
      def effect_table
        @effect_table || Effects::EffectTable.empty
      end

      # ADR-103 WD2 / WD6 / WD10 / #387 — the loaded plugins' effect contributions, compiled once per
      # process. Memoised on first use rather than built in the constructor for two reasons: the plugin
      # registry is adopted after construction (`apply_prebuilt` / the plugin-load pre-pass), and the
      # project's as-written superclass table — which is what makes an `ActiveRecord::Base` row reach
      # `User.find` — exists only once the cross-file discovery pre-pass has run, which it has by the time
      # any file is analyzed.
      #
      # Public and declared here beside the other effect surfaces: `rigor effects` builds its snapshot off
      # the run's own vocabulary and has to read the same compiled tables the collection window scanned
      # under.
      def effect_plugin_facts
        @effect_plugin_facts ||= Effects::PluginFacts.build(
          @plugin_registry, superclasses: @project_discovered_superclasses
        )
      end

      # The merged per-file collections behind {#effect_table} — the *direct* summaries, before the graph
      # closure. #381's snapshot records these, because a diff over direct summaries stays attributable to
      # the pull request's own lines.
      def effect_collection
        Effects::FileCollection.merge_all(effect_collections)
      end

      # Issue #382 — the same collections keyed by the path that produced each, which is the form the two
      # caches persist: `{ "lib/a.rb" => FileCollection, … }`. The merged {#effect_collection} cannot be
      # persisted per file (merging is where the path is deliberately dropped), and per file is what an
      # ADR-46 recheck needs — it re-collects the changed closure and serves the rest from the snapshot.
      def effect_collections_by_path
        pooled = @pool_coordinator.collected_effects
        pooled.empty? ? @file_effects.dup : @file_effects.merge(pooled)
      end

      # Issue #382 — adopt persisted collections as this run's own and close the graph over them. The
      # warm-hit half of the whole-run effects slot: the analysis did not run, so `#assemble_run_diagnostics`
      # never reached {#close_effect_graph} and the fixpoint is run here instead. The fixpoint is ALWAYS
      # re-run rather than persisted — it is the cheap half, and a stored table would have to be invalidated
      # by every input a summary has.
      def adopt_effect_collections(collections)
        @file_effects = collections
        close_effect_graph
      end

      # Issue #382 — whether this run's effect collections came from the whole-run effects slot rather than
      # from a fresh collection pass. Read by the specs and by nothing in the engine; `#effect_table` reads
      # the same either way, which is the property the slot exists to provide.
      def effects_served_from_cache?
        @effects_served_from_cache
      end

      # Which file each effect unit was defined in — `{ "Class#m" => [path, …] }`, sorted, one entry per
      # file that contributes a `def` to the key (a reopening spans several).
      #
      # The merged {#effect_collection} cannot answer this: merging drops the per-file path, deliberately,
      # because a summary is line- and file-free by design. The snapshot's `reach:` table needs it anyway —
      # its entry points are named by *file* globs (`effects.snapshot.reach:`, the `unused --entry-point`
      # syntax), so the key has to be traced back to the file it was written in.
      def effect_sources
        effect_collections.each_with_object({}) do |collection, out|
          path = collection.path
          next if path.nil?

          collection.summaries.each_key { |key| (out[key] ||= []) << path }
        end
      end

      # @param configuration [Rigor::Configuration]
      # @param explain [Boolean] surface fail-soft fallback events as `:info` diagnostics.
      # @param cache_store [Rigor::Cache::Store, nil] the persistent cache the runner exposes to producers
      #   (`RbsConstantTable` and successors). Pass `nil` to disable caching for this run; the CLI's
      #   `--no-cache` flag wires `nil` through. v0.0.9 group A slice 1 introduces the surface; later
      #   slices route real producers through it.
      # @param workers [Integer] ADR-15 Phase 4b — when greater than zero, per-file analysis dispatches
      #   across a pool of N workers. Default `0` keeps the sequential code path bit-for-bit unchanged.
      #   Controlled via the `RIGOR_RACTOR_WORKERS` env var or `.rigor.yml` `parallel.workers:` (Phase 4c,
      #   fully wired).
      # @param collect_stats [Boolean] when true (default), `#run` builds a {RunStats} summary exposed via
      #   `result.stats` — this forces the RBS env build at end-of-run so the `class_decl_paths` snapshot
      #   has real source attribution. Set to false to skip the stats summary entirely; the CLI's
      #   `--no-stats` threads `false` through to keep trivial-fixture runs from warming `.rigor/cache`.
      # @param prebuilt [Rigor::Analysis::ProjectScan, nil] when supplied, the runner adopts the pre-built
      #   plugin registry / dependency-source index / scanner outputs from the snapshot and skips the
      #   per-call pre-passes that produce them. Used by long-lived integrations
      #   (`Rigor::LanguageServer::ProjectContext`) to keep per-buffer requests fast — scanners walk the
      #   project once per generation rather than once per request, and plugin `#prepare` runs once per
      #   generation rather than once per request. Watched-file invalidation is the owner's responsibility;
      #   the runner trusts the snapshot it was given.
      # @param environment [Rigor::Environment, nil] opt-in Environment override. When supplied, sequential
      #   mode uses the provided env instance in `#analyze_files` instead of building a fresh one via
      #   `Environment.for_project`, and attaches the runner's per-run reporter pair onto the env's mutable
      #   `Reporters` slot via `Environment#attach_reporters!`. Long-lived consumers (LSP `ProjectContext`)
      #   pass a shared env so per-publish work doesn't repeat the `Environment.for_project` build (bundler
      #   / lockfile / collection discovery, RbsLoader construction). Pool mode ignores the override — each
      #   worker continues to build its own Environment.
      # @param discovery_seed [Hash, nil] issue #260 — opt-in cross-file discovery tables, keyed by
      #   {Scope::DiscoveryIndex} slot name, seeded onto every per-file scope through
      #   `project_scope_seed_tables`. The ONE deliberate exception to "a `prebuilt:` runner carries no
      #   discovery tables": {Protection::DiagnosticOracle} threads the table set Tier 2's site filter already
      #   judges anchors against, so a site admitted because a sibling-file class resolved is also a site the
      #   oracle can kill at. nil (the default) leaves the prebuilt/LSP contract byte-identical.
      # @param no_tolerated_effects [Boolean] ADR-103 WD1 / #385 — `rigor check --no-tolerated-effects`.
      #   Judges effect envelopes as if `effects.tolerated:` were empty. A judgment-time switch only: the
      #   run, its collection and its cache identity are unchanged.
      def initialize(configuration:, explain: false, # rubocop:disable Metrics/ParameterLists,Metrics/AbcSize,Metrics/MethodLength
                     cache_store: Cache::Store.new(root: DEFAULT_CACHE_ROOT),
                     plugin_requirer: nil, workers: 0, collect_stats: true,
                     buffer: nil, prebuilt: nil, environment: nil,
                     record_dependencies: false, record_self_calls: false, analyze_only: nil,
                     seed_bundles: nil, collect_seed_bundles: false, param_inferred_types: nil,
                     discovery_seed: nil, no_tolerated_effects: false)
        @configuration = configuration
        @explain = explain
        @cache_store = enforce_read_only_cache(cache_store, buffer)
        @plugin_requirer = plugin_requirer
        @workers = workers
        @collect_stats = collect_stats
        @buffer = buffer
        @prebuilt = prebuilt
        @environment_override = environment
        # ADR-46 slice 1 — opt-in cross-file dependency recording. Off by default; when true,
        # `analyze_file` records each file's cross-file reads into `file_dependencies` (the incremental
        # cache, a later slice, consumes them).
        @record_dependencies = record_dependencies
        # ADR-24 slice 4a — opt-in unresolved-implicit-self-call recording. Off by default; when true,
        # `analyze_file` activates the engine choke-point recorder and collects each file's misses into
        # `unresolved_self_calls` (a later closed-class-gated rule consumes them). Purely observational —
        # diagnostics are byte-identical.
        @record_self_calls = record_self_calls
        @unresolved_self_calls = {}
        # ADR-103 WD13 — effect collection. Derived from the configuration, never from a flag: the
        # `effects:` block (or an implicit one, which is how `rigor effects` opts in) is the ONLY switch.
        # Observational — diagnostics are byte-identical whichever way it resolves.
        @record_effects = configuration.effects_enabled?
        # ADR-103 WD6 / #385 — the project's `effects.attribution:` table, built once and carried on the
        # collection window so a fork-pool worker scans under the same claims the parent does.
        @effect_attribution = Effects::Attribution.build(configuration.effects_attribution)
        # ADR-103 WD6 / #386 — the call-site envelope index, built lazily off the run's environment
        # (`#effect_envelope_index`) because the strata it reads include the built RBS one.
        @effect_envelope_index = nil
        @effect_envelope_index_env = nil
        # ADR-103 WD1 invariant 3 / #385 — `--no-tolerated-effects`, the audit switch. It changes the
        # JUDGMENT only: collection, the propagated table and the cache identity are all untouched, so an
        # audit run and an ordinary one share a cache entry and differ solely in which lane the envelope
        # check reads.
        @no_tolerated_effects = no_tolerated_effects
        @file_effects = {}
        @effect_table = nil
        @effects_served_from_cache = false
        @run_dependency_descriptor = nil
        # Memoised activation decision for the `call.self-undefined-method` rule (nil = not yet computed).
        # See `self_undefined_rule_active?`.
        @self_undefined_rule_active = nil
        @analyzed_files = [].freeze
        # In-memory source map for `#run_source` — `{ logical_path => source String }`. When set,
        # `parse_source` reads bytes from here instead of disk and `expand_paths` accepts the (possibly
        # non-existent) logical path. nil on a normal disk-backed run.
        @in_memory_sources = nil
        # ADR-46 slice 2 — the subset-analysis hook. When set (a collection of paths), the whole-project
        # pre-pass still runs over every file (so the cross-file index is complete), but only files in this
        # set are analyzed for diagnostics — the body tier re-analyses the affected closure and serves the
        # rest from the per-file cache. `nil` (the default) analyzes everything.
        @analyze_only = analyze_only && Set.new(analyze_only)
        # ADR-85 WD2 — seed-bundle discovery. When `collect_seed_bundles`, the cross-file discovery pre-pass
        # rebuilds from the prior run's per-file bundles (`@restored_seed_bundles`, re-walking only changed
        # files) instead of parsing every file, and exposes the refreshed set via `#seed_bundles` for the
        # session to persist. Off by default — a plain `rigor check` keeps today's parse+walk.
        @collect_seed_bundles = collect_seed_bundles
        @restored_seed_bundles = seed_bundles || {}
        @seed_bundles = {}.freeze
        # ADR-67 WD6c lift — a precomputed inferred-param table. When the incremental session already ran the
        # collector (it must, to diff the table against its snapshot BEFORE deciding the re-analyse closure),
        # it hands the result here so `seed_parameter_inference` seeds without a second whole-project collect
        # — and so the table the diff was decided on and the table this run seeds from are the SAME object,
        # not merely an equal recomputation. nil (the default) keeps the runner self-sufficient.
        @param_inferred_types_override = param_inferred_types
        # Issue #260 — the opt-in cross-file discovery seed (see the `discovery_seed:` doc above). Frozen and
        # never mutated; `project_scope_seed_tables` starts from a copy of it and lets any table this run
        # actually computed win.
        @discovery_seed = discovery_seed&.freeze
        @file_dependencies = {}
        @plugin_registry = Plugin::Registry::EMPTY
        @dependency_source_index = DependencySourceInference::Index::EMPTY
        @rbs_extended_reporter = RbsExtended::Reporter.new
        @boundary_cross_reporter = DependencySourceInference::BoundaryCrossReporter.new
        @source_rbs_synthesis_reporter = Plugin::SourceRbsSynthesisReporter.new
        # `#run` resets these for each invocation; pre-seed them to empty containers so `build_run_stats` /
        # `pre_file_diagnostics` (private, called only from `#run`) can read them without nil-guards. The
        # four end-of-pass snapshots (RBS class / signature-path tables, synthesized-namespace names,
        # `rigor:v1:conforms-to` results) live in one shared mutable {RunSnapshots} sink so the analysis
        # path that writes them and the run / aggregator code that reads them stay in separate
        # collaborators without a back-reference cycle.
        @snapshots = RunSnapshots.new
        @cached_plugin_prepare_diagnostics = [].freeze
        @project_discovered_classes = {}.freeze
        @project_discovered_def_nodes = {}.freeze
        @project_discovered_singleton_def_nodes = {}.freeze
        @project_discovered_def_sources = {}.freeze
        @project_discovered_singleton_def_sources = {}.freeze
        @project_discovered_superclasses = {}.freeze
        @project_discovered_includes = {}.freeze
        @project_discovered_class_sources = {}.freeze
        @project_discovered_method_visibilities = {}.freeze
        @project_discovered_methods = {}.freeze
        @project_data_member_layouts = {}.freeze
        @project_struct_member_layouts = {}.freeze
        # ADR-67 WD6a — the call-site parameter-inference table, populated by the opt-in pre-pass in
        # `assemble_run_diagnostics` when `parameter_inference:` is enabled, then seeded onto every per-file
        # scope (sequential + fork-worker) through `project_scope_seed_tables`. Empty by default, so the gate-off
        # run carries no table and is byte-identical.
        @project_param_inferred_types = {}.freeze
        # Issue #352 / ADR-17 — the `pre_eval:` constant publication table, populated by
        # `seed_pre_eval_constants` in `assemble_run_diagnostics` and seeded onto every per-file scope
        # (sequential + fork-worker) through `project_scope_seed_tables`. Empty unless the project lists
        # `pre_eval:` files that declare publishable constants, so a project without one is byte-identical.
        @project_pre_eval_constants = {}.freeze
        # ADR-84 WD2 — per-run identity token for the user-method return memo's bucket (see
        # Scope::DiscoveryIndex#run_generation). Minted fresh in `run_analysis` so the memo never serves an
        # entry across a run boundary (LSP re-check, ADR-62 warm loop); nil until the first run so
        # runner-less probes keep the per-file fallback.
        @run_generation = nil
        build_collaborators
      end

      # ADR-pending editor mode — present when the runner is wired for the `--tmp-file` / `--instead-of`
      # buffer-binding shape (`docs/design/20260516-editor-mode.md`). Nil for normal project runs.
      attr_reader :buffer

      # Walks every Ruby file under `paths`, parses it, builds a per-node scope index through
      # `Rigor::Inference::ScopeIndexer`, and runs the `Rigor::Analysis::CheckRules` catalogue over it.
      # Returns a `Rigor::Analysis::Result` aggregating every produced diagnostic plus any Prism parse
      # errors. The Environment is built once at run start through `Environment.for_project` so all files
      # share the same RBS load.
      def run(paths = @configuration.paths)
        # One per-run file-digest memo spans the whole run, so a path is SHA-256'd at most once across the
        # run-diagnostics dependency descriptor, its `fresh?` validation, the RBS signature tree, and every
        # plugin producer's watched-glob validation (they overlap heavily on the warm path). The nested ADR-85
        # WD3 memo yields one stable `Prism::DefNode` per resolved bundle handle for the run (both are no-ops
        # outside their respective consumers — an empty thread-local table).
        # ADR-87 WD1 — `cache.validation` (or the RIGOR_STRICT_VALIDATION env, which wins) selects the
        # freshness path for this run; the `auto` default resolves strict in CI (#190), stat-first elsewhere.
        Cache::FileDigest.with_run(strict: @configuration.cache_validation_strict?) do
          Inference::DefNodeResolver.with_run { run_analysis(paths) }
        end
      end

      def run_analysis(paths)
        Inference::MethodDispatcher::FileFolding.fold_platform_specific_paths =
          @configuration.fold_platform_specific_paths

        wall_started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        target_ruby_error = validate_target_ruby
        return Result.new(diagnostics: [target_ruby_error]) if target_ruby_error

        expansion = expand_paths(paths)
        @snapshots.reset_for_run
        # Per-run reset of the deferred-discovery memo (see `#ensure_project_discovery`).
        @project_discovery_done = false
        # Per-run reset of the environment the cacheable path resolves, reused by the envelope pass so a
        # run never builds two.
        @run_environment = nil
        # ADR-84 WD2 — roll the return-memo bucket: a fresh frozen token per run makes every per-file scope
        # of THIS run share one memo bucket while entries from any earlier run in this process (stale after
        # an edit) become unreachable.
        @run_generation = Object.new.freeze

        if @prebuilt
          adopt_prebuilt_project_scan(@prebuilt)
        else
          run_project_pre_passes(expansion: expansion)
        end

        # The recording / subset (ADR-46) modes read the discovery tables outside the analysis assembly, so
        # they force the build eagerly here (matching pre-slice-1 timing); every other mode defers it to the
        # miss path so a warm cache HIT skips the two whole-project parse passes entirely.
        ensure_project_discovery(expansion) if force_eager_discovery?

        diagnostics = compute_run_diagnostics(expansion)
        # ADR-103 WD12 / #383 — `effect.envelope-exceeded`, recomputed every run from the (possibly
        # cached) effect table and never stored. It sits OUTSIDE `compute_run_diagnostics` on purpose:
        # the `effects:` block is absent from the diagnostics cache identity, so a finding written into
        # that entry would outlive the configuration that produced it. See {EffectEnvelopePass}.
        diagnostics += effect_envelope_diagnostics(expansion)
        # ADR-103 WD13 commitment 1 / #384 — the mirror image: a project that wrote effect annotations
        # and NO `effects:` block. Same placement rationale (the block is absent from the diagnostics
        # cache identity, so a residual stored there would outlive the edit that answers it), and the
        # opposite gate, so exactly one of the two ever runs.
        diagnostics += effect_annotation_residual_diagnostics

        Result.new(
          diagnostics: @diagnostic_aggregator.apply_severity_profile(diagnostics),
          stats: stats_for_run(wall_started_at: wall_started_at, expansion: expansion)
        )
      end

      # Analyze a single source String in memory, without writing it to disk — a clean entry point for
      # embedders (LSP / editor mode) and a faster spec path than the per-call tmpdir + chdir. The source
      # is bound to `path` (purely a logical identity carried in diagnostic locations; it need not exist on
      # disk). The full run machinery still runs — environment build, plugin `prepare`, severity profile —
      # so the result matches a one-file disk run; only the cross-file project pre-pass is empty (there is
      # one file, and the per-file indexer self-discovers its own classes / defs).
      #
      # @param source [String] Ruby source to analyze.
      # @param path [String] logical path for diagnostic locations.
      # @return [Result]
      def run_source(source:, path: "(source).rb")
        @in_memory_sources = { path => source }
        run([path])
      ensure
        @in_memory_sources = nil
      end

      # ADR-46 — the project file set that a run over `paths` would analyze, computed by globbing only (no
      # RBS environment build), so the incremental fingerprint can be derived cheaply on the warm path
      # before deciding whether to build the env at all.
      def analysis_file_set(paths = @configuration.paths)
        expand_paths(paths).fetch(:files)
      end

      # ADR-46 §2 — inverts {#file_dependencies} into the reverse edge the incremental step walks:
      # `dependents[X] = { A : A read a declaration / body from X }`. On an edit to X, the body tier
      # (slice 2) re-analyses `{X} ∪ dependents[X]` and serves every other file from the per-file cache.
      # Built on demand from the recorded `sources` sets (so it reflects whatever `analyze_file` captured —
      # empty unless the runner was constructed with `record_dependencies: true`). The negative (`missing`)
      # edges are NOT inverted here: they feed the structural tier (slice 3), which re-checks a consumer
      # when a name it looked up and did not resolve later appears.
      def file_dependents
        Incremental.invert(file_dependencies.transform_values(&:sources))
      end

      # ADR-46 slice 4 — per-symbol body fingerprints, computed from the project pre-pass def index. Returns
      # a frozen hash of the form:
      #   { "path/to/file.rb" => { "ClassName#method" => sha256_hex, … }, … }
      # Used by {Analysis::IncrementalSession} to detect which symbols in a changed file actually changed
      # bodies, so only callers of those specific symbols are re-checked. Only meaningful after a run that
      # populated `@project_discovered_def_nodes` (i.e. any full or subset analysis); returns an empty
      # frozen hash before the first run.
      def symbol_fingerprints
        result = Hash.new { |h, k| h[k] = {} }
        collect_symbol_fingerprints(result, @project_discovered_def_sources, @project_discovered_def_nodes, "#")
        # ADR-46 slice 4 (singleton) — class/singleton-method bodies live in the parallel singleton tables the
        # instance loop never read (recon S5). Fingerprint them under a `"Class.method"` key (the format the
        # `singleton_def_for` dependency edge uses) so a `def self.x` body edit produces a changed pair.
        collect_symbol_fingerprints(result, @project_discovered_singleton_def_sources,
                                    @project_discovered_singleton_def_nodes, ".")
        result.transform_values(&:freeze).freeze
      end

      # Folds one def-source/def-node table pair into the per-file fingerprint map under `separator` (`#`
      # instance, `.` singleton). `sources` supplies the `"path:line"` (a `Prism::Location` hides its file);
      # the node supplies the body fingerprint.
      def collect_symbol_fingerprints(result, sources, nodes, separator)
        sources.each do |class_name, methods|
          methods.each do |method_sym, path_line|
            path = path_line.split(":", 2).first
            node = nodes.dig(class_name, method_sym)
            next unless node

            # ADR-85 WD3 — on the incremental warm path an unchanged file's def is a `DefHandle` carrying the
            # slice fingerprint captured when its bundle was built (no re-parse); a live node (cold / re-walked
            # file) is sliced as before. This is the only value-deref consumer of the def-node table besides the
            # three accessor choke points.
            result[path]["#{class_name}#{separator}#{method_sym}"] =
              node.is_a?(Inference::DefHandle) ? node.fingerprint : Digest::SHA256.hexdigest(node.location.slice)
          end
        end
      end
      private :collect_symbol_fingerprints

      # ADR-46 slice 3 — per-file set of the qualified class/module names declared in that file. Used to
      # detect a class that *appeared* in an edit so a subclass whose ancestor was previously undefined
      # (and so recorded a negative class edge) is re-checked. Inverts the project class-source attribution
      # (class → declaring files).
      def class_declarations
        result = Hash.new { |hash, key| hash[key] = Set.new }
        @project_discovered_class_sources.each do |class_name, files|
          files.each { |file| result[file] << class_name }
        end
        result.transform_values(&:freeze).freeze
      end

      # ADR-67 WD6c lift — the inferred-param table this run seeded from (frozen; empty when
      # `parameter_inference:` is off or the pre-pass failed soft). The incremental session reads it back
      # after a baseline so the snapshot records the seeds the cached diagnostics were computed under.
      def param_inferred_types
        @project_param_inferred_types
      end

      # ADR-67 WD6c lift — computes the whole-project inferred-param table without running an analysis.
      # The incremental session calls this BEFORE deciding its re-analyse closure: the table's diff against
      # the snapshot's stored table is what invalidates a callee whose seeds moved because a *caller* file
      # changed. Same collector invocation as {#seed_parameter_inference} (one round, same workers), so the
      # session-computed table and an in-run collect are byte-identical by construction. Fails soft to the
      # empty table — which the caller's diff then treats as "every stored entry removed", the conservative
      # direction (those callees re-check).
      def collect_param_inference_table(files)
        return {}.freeze unless @configuration.parameter_inference

        environment = @pool_coordinator.resolve_sequential_environment(source_files: files)
        Inference::ParameterInferenceCollector.collect(
          files: files, environment: environment,
          target_ruby: @configuration.target_ruby, max_rounds: 1, workers: @workers
        )
      rescue StandardError
        {}.freeze
      end

      # ADR-89 WD2 — the per-method observed-key return summaries the run's ADR-84 return memo just captured.
      # For each project method with live memo entries, a bounded `{ keys:, returns:, effects: }` summary the
      # incremental session persists: `keys` the observed `[receiver, arg_types]` type tuples, `returns` their
      # `describe(:short)` descriptors, `effects` the content-mutated parameter positions (a caller-visible
      # arg-flooring surface). Only meaningful right after a run populated the memo (baseline / recheck),
      # before the bucket rolls. Keys are held live here; the session Marshals them for the snapshot.
      #
      # @return [Hash] `{ [path, "Class#method" | "Class.method"] => { keys:, returns:, effects: } }`.
      def return_summaries
        memo = Inference::ExpressionTyper.harvest_return_memo
        return {} if memo.empty?

        result = {}
        effects_evaluator = Inference::StatementEvaluator.new(scope: Scope.empty)
        collect_return_summaries(result, @project_discovered_def_nodes, @project_discovered_def_sources,
                                 "#", memo, effects_evaluator)
        collect_return_summaries(result, @project_discovered_singleton_def_nodes,
                                 @project_discovered_singleton_def_sources, ".", memo, effects_evaluator)
        result
      end

      # Folds one def-node/def-source table pair's memo entries into the return-summary result under
      # `separator`. A live def node (a cold / re-walked file) is the identity every cross-file caller
      # resolved through, so `memo[node]` holds those callers' observed keys; a {DefHandle} (an unchanged
      # file on the warm path) never keyed a memo entry, so it is skipped (its summary is carried over from
      # the snapshot). Bounded per def and in total so the snapshot stays small.
      def collect_return_summaries(result, nodes, sources, separator, memo, effects_evaluator)
        nodes.each do |class_name, methods|
          methods.each do |method_name, node|
            next if node.is_a?(Inference::DefHandle)

            entries = memo[node]
            next if entries.nil? || entries.empty?

            path_line = sources.dig(class_name, method_name)
            next if path_line.nil?

            break if result.size >= RETURN_SUMMARY_TOTAL_CAP

            capped = entries.first(RETURN_SUMMARY_KEYS_PER_DEF)
            result[[path_line.split(":", 2).first, "#{class_name}#{separator}#{method_name}"]] = {
              keys: capped.map { |entry| [entry.receiver, entry.arg_types] },
              returns: capped.map { |entry| entry.result.describe(:short) },
              effects: content_effects(effects_evaluator, node)
            }
          end
        end
      end

      # The content-mutated parameter positions of `node`, or `[]` if the computation raises (defensive: the
      # effects surface only routes attention, never soundness — a missing set reads as "no floor").
      def content_effects(effects_evaluator, node)
        effects_evaluator.content_mutated_parameter_positions(node)
      rescue StandardError
        []
      end

      # ADR-89 WD2 — re-evaluate the return type of specific project methods at previously-observed call keys,
      # WITHOUT analyzing any file. The incremental session calls this session-side (before dispatching the
      # recheck) to prove a declaration-stable, changed callee returns the same type at every key its baseline
      # callers used, so those callers' re-analysis can be skipped. Builds the cross-file discovery index (the
      # ADR-85 seed-bundle fold, re-walking only edited files) and the RBS environment (served from the cache
      # store) exactly as a real run's setup does, then re-drives each spec's def through the ADR-84 return
      # memo. Off any hot path — invoked only when declaration-stable changed pairs carry a persisted summary.
      #
      # @param paths [Array<String>, nil] analysis roots (nil → the configuration's `paths:`).
      # @param specs [Array<Hash>] each `{ class_name:, method_name:, singleton:, keys: [[receiver, args], …] }`.
      # @return [Hash] `{ [class_name, method_name, singleton] => [return_descriptor_or_nil, …] }`.
      def evaluate_return_types(paths, specs)
        return {} if specs.empty?

        Cache::FileDigest.with_run(strict: @configuration.cache_validation_strict?) do
          Inference::DefNodeResolver.with_run { evaluate_return_types_setup(paths, specs) }
        end
      end

      # Builds the discovery index + environment (a real run's prologue, minus per-file analysis) and
      # re-evaluates each spec's def. Extracted so {#evaluate_return_types}'s `with_run` wrappers stay thin.
      def evaluate_return_types_setup(paths, specs)
        expansion = expand_paths(paths || @configuration.paths)
        @project_discovery_done = false
        @run_generation = Object.new.freeze
        run_project_pre_passes(expansion: expansion)
        ensure_project_discovery(expansion)
        environment = @pool_coordinator.resolve_sequential_environment(source_files: target_files(expansion))
        specs.to_h do |spec|
          [[spec[:class_name], spec[:method_name], spec[:singleton]], evaluate_spec_returns(spec, environment)]
        end
      end

      # Re-evaluates one spec's def at each of its observed keys. Locates the (live) def node in the discovery
      # index, builds a project-seeded scope, and returns one return descriptor per key (nil when the def is
      # missing / bodyless or the memo refuses a transient result — the caller reads either as "not provably
      # stable" and keeps the dependents).
      def evaluate_spec_returns(spec, environment)
        table = spec[:singleton] ? @project_discovered_singleton_def_nodes : @project_discovered_def_nodes
        node = table.dig(spec[:class_name], spec[:method_name])
        node = Inference::DefNodeResolver.resolve(node) if node.is_a?(Inference::DefHandle)
        return spec[:keys].map { nil } if node.nil?

        scope = seed_project_scope(Scope.empty(environment: environment, source_path: spec[:path]))
        spec[:keys].map do |(receiver, arg_types)|
          result = scope.user_method_return(node, receiver, arg_types)
          result&.describe(:short)
        end
      end

      # ADR-45 — unchanged-project fast path. Serves the whole run's (pre-severity-profile) diagnostics
      # from one record-and-validate cache entry when every file the previous run read is unchanged,
      # skipping the dominant per-file inference. The dependency set is collected AFTER the run (so it
      # captures files the plugins read mid-analysis, e.g. a Pundit policy) and re-validated on the next
      # run; the entry is keyed on the inputs known up front (config, gem / engine versions, analyzed-path
      # set).
      def compute_run_diagnostics(expansion)
        @run_served_from_cache = false
        return assemble_run_diagnostics(expansion) unless run_result_cacheable?

        environment = @pool_coordinator.resolve_sequential_environment(source_files: target_files(expansion))
        # Lazy-files descriptor: the cache KEY reads only `gems` + `configs`; the RBS signature-tree `files`
        # are digested solely by `run_dependency_descriptor` on a MISS, so a warm HIT never walks the tree.
        rbs_descriptor = if environment&.rbs_loader
                           Cache::RbsDescriptor.build_run(environment.rbs_loader)
                         else
                           Cache::Descriptor.new
                         end
        @run_environment = environment
        key_descriptor = run_key_descriptor(expansion, rbs_descriptor)
        return assemble_run_diagnostics(expansion, environment: environment) if key_descriptor.nil?

        # ADR-103 WD13 / #382 — the effects slot is consulted FIRST, because it is the one that can force
        # the analysis: a missing or differently-identified sidecar is a miss for effects consumers only,
        # and the only way to re-collect is to re-analyze. When it hits (or collection is off) this returns
        # nil and the diagnostics slot decides on its own, exactly as it did before effects existed.
        analysis = serve_effect_collections(expansion, environment, key_descriptor, rbs_descriptor)
        computed = false
        diagnostics = @cache_store.fetch_or_validate(
          producer_id: RunCacheKey::RUN_DIAGNOSTICS_PRODUCER_ID, key_descriptor: key_descriptor,
          generation_cap: RunCacheKey::GENERATION_CAP
        ) do
          computed = true
          diags = analysis || assemble_run_diagnostics(expansion, environment: environment)
          [diags, run_dependency_descriptor(expansion, rbs_descriptor)]
        end
        # An effects miss that ran the analysis is not a cache-served run even when the diagnostics slot
        # then hit — the stats it would otherwise suppress were all gathered.
        @run_served_from_cache = !computed && analysis.nil?
        diagnostics
      rescue StandardError
        # The result cache must never break a run. If anything in the cache path fails, fall back to a
        # direct, uncached analysis.
        @run_served_from_cache = false
        assemble_run_diagnostics(expansion)
      end

      # ADR-103 WD13 / issue #382 — the whole-run **effects sidecar**, the second of "one cache, two
      # identities, one extra slot". Keyed by {Effects::Identity.descriptor} — the diagnostics key
      # descriptor plus the vocabulary version, the catalogue identity and the `effects:` digest — and
      # validated against the same post-run dependency descriptor the diagnostics slot records, so exactly
      # the file set that invalidates diagnostics invalidates summaries.
      #
      # Returns the diagnostics of the analysis it had to run (a miss — the run has to re-collect, and the
      # only way to collect is to analyze), or nil when it did not have to run one (a hit, or collection
      # off). The diagnostics slot is never written, read, or invalidated from here.
      def serve_effect_collections(expansion, environment, key_descriptor, rbs_descriptor)
        return nil unless @record_effects

        descriptor = effects_key_descriptor(key_descriptor)
        cached = descriptor && peek_effect_collections(descriptor)
        if cached
          adopt_effect_collections(cached)
          @effects_served_from_cache = true
          return nil
        end

        analysis = assemble_run_diagnostics(expansion, environment: environment)
        store_effect_collections(descriptor, expansion, rbs_descriptor)
        analysis
      end

      def effects_key_descriptor(key_descriptor)
        Effects::Identity.descriptor(base: key_descriptor, configuration: @configuration,
                                     plugin_facts: effect_plugin_facts)
      rescue StandardError
        nil
      end

      # The read half. A miss, a stale dependency, a corrupt entry and a stored value of the wrong shape
      # are one answer — nil, "collect it again" — because none of them can be told apart from the outside
      # and all of them have the same remedy.
      def peek_effect_collections(descriptor)
        cached = @cache_store.peek_validated(
          producer_id: RunCacheKey::RUN_EFFECTS_PRODUCER_ID, key_descriptor: descriptor
        )
        cached.is_a?(Hash) ? cached : nil
      rescue StandardError
        nil
      end

      # The write half, run only after a miss, so the block never recomputes anything: it hands over the
      # collections the analysis just produced, validated against the same post-run dependency descriptor
      # the diagnostics slot records. Fail-soft — a collection that will not Marshal (which nothing in
      # {Effects::FileCollection} should be, and the fork pool already proves per file) costs the next run
      # its warm start and nothing else.
      def store_effect_collections(descriptor, expansion, rbs_descriptor)
        return if descriptor.nil?

        collections = effect_collections_by_path
        @cache_store.fetch_or_validate(
          producer_id: RunCacheKey::RUN_EFFECTS_PRODUCER_ID, key_descriptor: descriptor,
          generation_cap: RunCacheKey::EFFECTS_GENERATION_CAP
        ) { [collections, run_dependency_descriptor(expansion, rbs_descriptor)] }
        nil
      rescue StandardError
        nil
      end
      private :serve_effect_collections, :effects_key_descriptor,
              :peek_effect_collections, :store_effect_collections

      # ADR-103 WD8 / #383 — the envelope check. Nothing at all without an `effects:` block, and nothing
      # under `effects.check: false`; with both, one walk of the project's own RBS for `%a{pure}` /
      # `%a{rigor:v1:effect …}`, and only if that finds an envelope does anything else run (the discovery
      # tables the `def` positions come from are forced from inside the pass, lazily, for that reason).
      #
      # The environment is the one the cacheable path already resolved when there is one, so a warm run
      # reads the envelopes off the loader it built anyway rather than building a second.
      def effect_envelope_diagnostics(expansion)
        return [] unless @record_effects && @configuration.effects_check?

        EffectEnvelopePass.new(
          configuration: @configuration,
          rbs_loader: envelope_rbs_loader(expansion),
          effect_table: effect_table,
          discovery: -> { envelope_discovery_tables(expansion) },
          sources: @in_memory_sources,
          unit_sources: effect_sources,
          # ADR-103 WD1 / #386 — the nominal relation `effect.liskov-widened` reads, from the collector's
          # own as-written superclass table, so the Liskov check and the closed-world proven lane resolve
          # the same ancestry. Lazy: only a project that declared an envelope pays the merge.
          ancestry: -> { effect_collection.superclasses },
          apply_tolerated: !@no_tolerated_effects,
          # #387 — the same compiled plugin tables the collection window scanned under, so an envelope may
          # name a label a plugin opened and the unknown-label check agrees with the scan.
          plugin_facts: effect_plugin_facts
        ).diagnostics
      end

      # The residual takes the loader the run ALREADY resolved — never `envelope_rbs_loader`, which
      # builds one on demand. This runs on the effects-off path, where an environment build is a cost
      # the project did not ask for; the `signature_paths:` `.rbs` stratum is always read, and the
      # rbs-inline stratum rides whatever the run happened to have.
      def effect_annotation_residual_diagnostics
        EffectAnnotationResidualPass.new(
          configuration: @configuration, rbs_loader: @run_environment&.rbs_loader
        ).diagnostics
      end

      def envelope_rbs_loader(expansion)
        environment = @run_environment ||
                      @pool_coordinator.resolve_sequential_environment(source_files: target_files(expansion))
        environment&.rbs_loader
      rescue StandardError
        nil
      end

      def envelope_discovery_tables(expansion)
        ensure_project_discovery(expansion)
        [@project_discovered_def_sources, @project_discovered_singleton_def_sources,
         @project_discovered_class_sources]
      end

      private :effect_envelope_diagnostics, :effect_annotation_residual_diagnostics,
              :envelope_rbs_loader, :envelope_discovery_tables

      # ADR-103 WD13 — fail-soft at the run level too: a propagator that raises leaves the table empty and
      # the run untouched. `Propagator.propagate` already swallows its own failures; this guards the merge.
      def close_effect_graph
        return unless @record_effects

        @effect_table = Effects::Propagator.propagate(effect_collection, discharge: effect_discharge)
      rescue StandardError
        @effect_table = Effects::EffectTable.empty
      end

      # ADR-103 WD14 / #385 — the `effects.tolerated:` policy the propagator's second (undischarged) lane
      # is computed under. Built from the configuration and never from the audit flag: BOTH lanes are in
      # the table, and `--no-tolerated-effects` picks the other one at judgment time, so one fixpoint
      # serves an audit run and an ordinary one alike.
      def effect_discharge
        @effect_discharge ||= Effects::Discharge.new(@configuration.effects_tolerated)
      end

      def assemble_run_diagnostics(expansion, environment: nil)
        # Force the deferred cross-file discovery pre-pass on the analysis (miss) path. Memoised, so the
        # eager force in `#run` (recording / subset modes) makes this a no-op. A warm cache HIT never calls
        # `assemble_run_diagnostics`, so it never runs the two whole-project parse passes. Runs over the FULL
        # expansion — subset (`analyze_only`) mode still needs the complete cross-file index (ADR-46 §2).
        ensure_project_discovery(expansion)
        # ADR-67 WD6a — the opt-in call-site parameter-inference pre-pass. Runs on the parent BEFORE the pool
        # split (so every worker sees the same frozen table — the seed-before-fork determinism the discovery
        # tables use) and only on the analysis (miss / non-cacheable) path (a warm ADR-45 cache HIT never
        # assembles). Gate off → no-op, and `environment` is left untouched so its lazy build timing is
        # unchanged. Returns the resolved environment so the sequential dispatch reuses it (no double build).
        environment = seed_parameter_inference(expansion, environment)
        # Issue #352 — the `pre_eval:` constant publication pre-pass. Same placement rationale as the line
        # above: it runs on the parent BEFORE the pool split so every worker sees the same frozen table, and
        # only on the analysis (miss) path. No `pre_eval:` entry → no-op, and `environment` passes through
        # untouched so its lazy build timing is unchanged.
        environment = seed_pre_eval_constants(expansion, environment)
        diagnostics = @diagnostic_aggregator.pre_file_diagnostics(expansion)
        # ADR-46 — record which project files this run actually analyzed (the `analyze_only` subset, or
        # all of them). The incremental orchestrator serves every analyzed-but-not-affected file from the
        # per-file cache, so it needs the full analyzed set to subtract the affected closure from.
        targets = target_files(expansion)
        @analyzed_files = targets
        diagnostics += @pool_coordinator.analyze_files(targets, environment: environment)
        # ADR-103 WD12 — the effect fixpoint, in the post-pool aggregation slot beside the conformance
        # results. Graph-only over a finite lattice, so it is a plain worklist to a true fixpoint; it
        # contributes NO diagnostics and its result leaves through `#effect_table`, never through the
        # stream. Skipped entirely when collection did not run.
        close_effect_graph
        diagnostics += @diagnostic_aggregator.rbs_quarantined_signature_diagnostics
        diagnostics += @diagnostic_aggregator.rbs_environment_build_failed_diagnostics
        diagnostics += @diagnostic_aggregator.rbs_synthesized_namespace_diagnostics
        diagnostics += @diagnostic_aggregator.conforms_to_diagnostics
        diagnostics += @diagnostic_aggregator.rbs_extended_reporter_diagnostics
        diagnostics += @diagnostic_aggregator.boundary_cross_diagnostics
        diagnostics + @diagnostic_aggregator.source_rbs_synthesis_diagnostics
      end

      # ADR-67 WD6a — the check-walk parameter-inference pre-pass. Populates `@project_param_inferred_types`
      # (read by `project_scope_seed_tables`) with the call-site union of every undeclared parameter, running
      # ONE round (a single hop of call-site → param typing; the protection scan's three-round fixpoint stays a
      # protection-surface luxury until measured). No-op unless `parameter_inference:` is enabled, so the
      # default run pays exactly nothing here and `environment` passes through unchanged (preserving the lazy
      # env-build timing). When enabled, it resolves the environment once — the collector types call-site
      # arguments against the same RBS / plugin surface the check uses — and returns it so the sequential
      # dispatch reuses that build. The whole-project file set (not the `analyze_only` subset) is scanned: the
      # inference is cross-file (a call site in one file types a parameter in another). Fails soft — a collector
      # error must never break a run, so the table stays empty and the run proceeds unseeded.
      def seed_parameter_inference(expansion, environment)
        return environment unless @configuration.parameter_inference

        if @param_inferred_types_override
          @project_param_inferred_types = @param_inferred_types_override
          return environment
        end

        files = expansion.fetch(:files)
        environment ||= @pool_coordinator.resolve_sequential_environment(source_files: files)
        @project_param_inferred_types = Inference::ParameterInferenceCollector.collect(
          files: files, environment: environment,
          target_ruby: @configuration.target_ruby, max_rounds: 1, workers: @workers
        )
        environment
      rescue StandardError
        @project_param_inferred_types = {}.freeze
        environment
      end

      # Issue #352 / ADR-17 — the `pre_eval:` CONSTANT publication pre-pass, the twin of the slice-2 patched-
      # METHOD registry the eager pre-passes already build. Walks each listed file's constant writes with the
      # per-file pre-pass ({Inference::ScopeIndexer.build_in_source_constants}) under a project-seeded scope,
      # widens each result to its erased class, and populates `@project_pre_eval_constants` — which
      # `project_scope_seed_tables` then seeds onto every per-file scope, so `TIMEOUT = 30` in a listed file
      # reads as `Integer` instead of `Dynamic[top]` in its consumers. The widening + multi-file conflict rules
      # live in {Inference::PreEvalConstants}.
      #
      # Runs here rather than in {ProjectPrePasses#run} because typing a constant's rvalue needs the RBS
      # environment, which the eager pre-passes feed rather than consume. Fails soft — a collector error must
      # never break a run, so the table stays empty and the run proceeds exactly as it does today.
      def seed_pre_eval_constants(expansion, environment)
        paths = @configuration.pre_eval.select { |path| File.file?(path) }
        return environment if paths.empty?

        environment ||= @pool_coordinator.resolve_sequential_environment(source_files: expansion.fetch(:files))
        @project_pre_eval_constants = Inference::PreEvalConstants.collect(
          paths: paths, target_ruby: @configuration.target_ruby, buffer: @buffer,
          scope_builder: lambda { |path|
            seed_project_scope(Scope.empty(environment: environment, source_path: path))
          }
        )
        environment
      rescue StandardError
        @project_pre_eval_constants = {}.freeze
        environment
      end

      # A cache hit skipped the analysis, so the per-run stats (wall split, RBS-class counts, …) were never
      # gathered — report none rather than the stale snapshot defaults.
      def stats_for_run(wall_started_at:, expansion:)
        return nil unless @collect_stats
        return nil if @run_served_from_cache

        build_run_stats(wall_started_at: wall_started_at, expansion: expansion)
      end

      # Cacheable only for a full sequential project run with a writable cache and no per-buffer /
      # prebuilt override — every other mode has a different result identity (pool workers read in
      # separate processes; editor mode is per-buffer; prebuilt is the LSP path).
      #
      # The ADR-46 incremental modes are excluded too, now that they carry a real cache store (ADR-85
      # WD1): a `record_dependencies` run MUST perform per-file analysis to capture the dependency
      # graph (a cache-served run records nothing, leaving the next recheck's dependents empty —
      # unsound), and an `analyze_only` subset run produces intentionally partial diagnostics that
      # share the full run's result key (`run_key_descriptor` keys on the whole expansion, not the
      # subset), so serving one as the other would manufacture a wrong result. Both instead use the
      # store for the RBS-env + plugin-producer tiers, where the incremental win actually lives.
      # ADR-103 WD13 / issue #382 — a COLLECTING run is no longer excluded. It was, for the same reason a
      # `record_dependencies` run is (a cache-served run collects nothing, so `#effect_table` would come
      # back empty from a warm hit), and the sidecar slot is what lifts it: the collections ride their own
      # entry under their own identity, so a warm run restores them and re-runs only the fixpoint. A run
      # with collection OFF never reads or writes that slot and is byte-identical here.
      def run_result_cacheable?
        !@cache_store.nil? && !@cache_store.read_only? &&
          @buffer.nil? && @prebuilt.nil? && !pool_mode? &&
          !@record_dependencies && @analyze_only.nil?
      end

      # Stable cache key inputs — known before the run: a digest of the resolved configuration, the engine
      # + rbs versions + `--explain`, and the analyzed-path SET (adding/removing a file changes the key;
      # editing one is caught by dependency validation). nil disables the cache for this run rather than
      # risking a malformed key.
      def run_key_descriptor(expansion, rbs_descriptor)
        # ADR-87 WD4 — the key is built through the shared {RunCacheKey} builder the boot-slimming probe also
        # uses, so the miss path (here, passing the loader's `rbs_descriptor.configs`) and the hit path (which
        # reconstructs `rbs.libraries` from config) can never drift out of key agreement.
        RunCacheKey.descriptor(
          configuration: @configuration, files: expansion.fetch(:files),
          explain: @explain, rbs_config_entries: rbs_descriptor.configs
        )
      end

      # Files the run actually depended on, collected AFTER it ran: every analyzed file, every RBS `sig`
      # file (`rbs_descriptor.files`), and every file each plugin read (complete post-run, so reads made
      # mid-analysis are included). Re-digested on the next run by {Descriptor#fresh?}.
      # Memoised because a collecting run asks twice — once to validate the effects sidecar it just wrote,
      # once for the diagnostics entry — and this is a whole-project stat + digest walk. Both asks happen
      # after the same analysis, so they are answering about the same world; a run with collection off asks
      # once and the memo is inert.
      def run_dependency_descriptor(expansion, rbs_descriptor)
        @run_dependency_descriptor ||= build_run_dependency_descriptor(expansion, rbs_descriptor)
      end

      def build_run_dependency_descriptor(expansion, rbs_descriptor)
        entries = analyzed_file_entries(expansion) + pre_eval_file_entries + rbs_descriptor.files
        @plugin_registry.plugins.each do |plugin|
          # Read the boundary WITHOUT triggering its lazy `@io_boundary ||=` initializer: plugin instances
          # are frozen after the run, and a plugin that never built a boundary read no files through it,
          # so it contributes no dependencies.
          boundary = plugin.instance_variable_get(:@io_boundary)
          entries.concat(boundary.cache_descriptor.files) if boundary
        end
        Cache::Descriptor.new(files: entries)
      end

      def analyzed_file_entries(expansion)
        expansion.fetch(:files).map do |path|
          physical = @buffer ? @buffer.resolve(path) : path
          # ADR-87 WD1 — validation-only dependency descriptor, so the stat-then-digest `:stat` comparator
          # applies (the env-cache KEY files stay `:digest`).
          Cache::Descriptor::FileEntry.stat(path: physical, digest: Cache::FileDigest.hexdigest(physical))
        end
      end

      # Issue #352 — a `pre_eval:` file is a real input to the run's diagnostics: its `def`s populate the
      # ADR-17 patched-method registry and (since #352) its constants populate the project seed. ADR-17 WD5
      # permits listing a file under `pre_eval:` and NOT under `paths:`, and such a file never appears in the
      # expansion — so without this entry, editing one would leave the run-result cache serving diagnostics
      # computed against the previous version. The common case (a `lib/core_ext/` file that is also under
      # `paths:`) contributes a duplicate entry, which the descriptor's per-path validation absorbs.
      def pre_eval_file_entries
        @configuration.pre_eval.filter_map do |path|
          physical = @buffer ? @buffer.resolve(path) : path
          next unless File.file?(physical)

          Cache::Descriptor::FileEntry.stat(path: physical, digest: Cache::FileDigest.hexdigest(physical))
        end
      end

      # Runs every project-wide pre-pass (`load_plugins` +
      # `plugin#prepare` + dependency-source builder +
      # synthetic-method scanner + project-patched scanner)
      # exactly once, then returns a frozen
      # {Rigor::Analysis::ProjectScan} snapshot.
      #
      # Long-lived integrations (`Rigor::LanguageServer::ProjectContext`)
      # call this once per project-state generation and feed the
      # snapshot back into `Runner.new(prebuilt: scan)` for every
      # subsequent per-buffer publish. The cold pre-pass cost is
      # paid once per generation rather than once per keystroke.
      #
      # Notes for callers:
      # - The runner this method is called on may be a "build only"
      #   instance — `@buffer` is typically nil so the scanners
      #   observe on-disk bytes for the full project. Callers that
      #   want pre-passes to see a particular buffer's edits should
      #   build the runner WITH `buffer:` set.
      # - The returned ProjectScan is frozen and shareable; the
      #   underlying `plugin_registry` is the same object that ran
      #   `#prepare`, so the per-plugin `services.fact_store` is
      #   already populated for subsequent dispatch use.
      def prepare_project_scan(paths: @configuration.paths)
        expansion = expand_paths(paths)
        result = @pre_passes.run(expansion: expansion)
        apply_pre_passes_result(result)
        @pre_passes.build_project_scan(result)
      end

      # Internal: drives every project-wide pre-pass through the
      # {ProjectPrePasses} collaborator and adopts the resulting
      # state onto the runner's ivar surface in the order the
      # downstream `#run` body expects. Shared by `#prepare_project_scan`
      # and the prebuilt-less `#run` path.
      def run_project_pre_passes(expansion:)
        apply_pre_passes_result(@pre_passes.run(expansion: expansion))
      end

      # Internal: adopts a frozen {ProjectScan} snapshot supplied
      # to `Runner.new(prebuilt: ...)` by storing each slot on
      # the runner's ivar surface, mirroring what
      # `run_project_pre_passes` would have produced.
      def adopt_prebuilt_project_scan(scan)
        apply_pre_passes_result(@pre_passes.adopt_prebuilt(scan))
      end

      # Internal: copies a {ProjectPrePasses::Result} bundle's EAGER (env-input) slots onto the runner's
      # ivars, so every downstream reader (pool environment build, diagnostic aggregator) sees the same ivar
      # surface. The cross-file discovery tables are NOT carried here — `#run` (prebuilt-less) and
      # `adopt_prebuilt` both leave them at their frozen-empty constructor defaults, and the analysis path
      # fills them lazily via {#ensure_project_discovery}. The prebuilt (LSP) path never fills them, matching
      # the original adopt behaviour that seeded an empty project scope — with ONE deliberate exception, the
      # opt-in `discovery_seed:` constructor seam (issue #260), which bypasses the ivars entirely and rides
      # `project_scope_seed_tables`. A prebuilt runner constructed without it is unchanged.
      def apply_pre_passes_result(result)
        @plugin_registry = result.plugin_registry
        @dependency_source_index = result.dependency_source_index
        @cached_plugin_prepare_diagnostics = result.cached_plugin_prepare_diagnostics
        @synthetic_method_index = result.synthetic_method_index
        @project_patched_methods = result.project_patched_methods
        @pre_eval_diagnostics_from_scanner = result.pre_eval_diagnostics_from_scanner
      end

      # Internal: adopts a {ProjectPrePasses::Discovery} bundle (the two whole-project discovery passes)
      # onto the runner's discovery ivars, in the same assignment order the original inline pre-pass used.
      # Called only from {#ensure_project_discovery}.
      def apply_discovery_result(discovery)
        @project_discovered_classes = discovery.discovered_classes
        @project_discovered_def_nodes = discovery.discovered_def_nodes
        @project_discovered_singleton_def_nodes = discovery.discovered_singleton_def_nodes
        @project_discovered_def_sources = discovery.discovered_def_sources
        @project_discovered_singleton_def_sources = discovery.discovered_singleton_def_sources
        @project_discovered_superclasses = discovery.discovered_superclasses
        @project_discovered_includes = discovery.discovered_includes
        @project_discovered_class_sources = discovery.discovered_class_sources
        @project_discovered_method_visibilities = discovery.discovered_method_visibilities
        @project_discovered_methods = discovery.discovered_methods
        @project_data_member_layouts = discovery.data_member_layouts
        @project_struct_member_layouts = discovery.struct_member_layouts
      end

      # Internal: builds the deferred cross-file discovery tables at most once per run and adopts them.
      # Memoised on `@project_discovery_done` (reset at the start of `#run`). No-op under `@prebuilt` — the
      # LSP path deliberately seeds an empty project scope from a snapshot that carries no discovery tables,
      # so forcing a build there would change that contract. A caller that DOES want cross-file knowledge under
      # `prebuilt:` supplies it explicitly through `discovery_seed:` (issue #260) rather than by re-walking the
      # project here. Called eagerly from `#run` for the recording /
      # subset (ADR-46) modes and lazily from `#assemble_run_diagnostics` on the analysis path, so a warm
      # cache HIT (which never assembles) never pays the double parse.
      def ensure_project_discovery(expansion)
        return if @prebuilt
        return if @project_discovery_done

        @project_discovery_done = true
        if @collect_seed_bundles
          # ADR-85 WD2 — rebuild discovery from the prior run's bundles (re-walking only changed files) and
          # capture the refreshed bundle set for the session to persist.
          discovery, @seed_bundles = @pre_passes.discover_from_bundles(
            expansion: expansion, seed_bundles: @restored_seed_bundles
          )
          apply_discovery_result(discovery)
        else
          apply_discovery_result(@pre_passes.discover(expansion: expansion))
        end
      end

      # ADR-46 — the dependency-recording and subset-analysis modes read the discovery tables OUTSIDE the
      # analysis assembly (`Runner#symbol_fingerprints` / `#class_declarations`, consumed by
      # {IncrementalSession} after the run), so they force the build eagerly — matching the pre-slice-1
      # timing where discovery always ran before `compute_run_diagnostics`. Every other mode defers to the
      # lazy build inside `#assemble_run_diagnostics`.
      def force_eager_discovery?
        @record_dependencies || !@analyze_only.nil?
      end

      private :run_project_pre_passes, :adopt_prebuilt_project_scan, :apply_pre_passes_result,
              :apply_discovery_result, :ensure_project_discovery, :force_eager_discovery?

      # Ruby versions probed (ascending) to discover the lowest one this Prism build accepts for
      # `version:`. Prism exposes no version list, so the floor is found empirically — only when a
      # misconfigured `target_ruby` is rejected — so the diagnostic can name it instead of leaving the user
      # to guess (the dogfood field trial, 20260620-skill-driven-onboarding-dogfood.md, burned cycles on
      # exactly this).
      PRISM_VERSION_LADDER = %w[
        3.0.0 3.1.0 3.2.0 3.3.0 3.4.0 3.5.0 4.0.0 4.1.0 4.2.0
      ].freeze

      # @return [String, nil] the lowest `target_ruby` this Prism build accepts, or nil if none of the
      #   ladder parses. Memoised per process (the value is constant for a given Prism).
      def self.prism_supported_floor
        @prism_supported_floor ||= PRISM_VERSION_LADDER.find do |candidate|
          Prism.parse("nil", version: candidate)
          true
        rescue ArgumentError
          false
        end
      end

      # `target_ruby` flows through to Prism's `version:` option. Prism enforces the supported range and
      # raises `ArgumentError` for versions it does not recognise. Run a one-time smoke parse here so a
      # misconfigured target_ruby surfaces as a single project-level diagnostic instead of crashing the
      # whole run on the first file — and name the supported floor + where to read the right value, so the
      # fix is obvious without a guess-and-retry loop.
      def validate_target_ruby
        Prism.parse("nil", version: @configuration.target_ruby)
        nil
      rescue ArgumentError => e
        floor = self.class.prism_supported_floor
        Diagnostic.new(
          path: ".rigor.yml", line: 1, column: 1,
          message: "target_ruby #{@configuration.target_ruby.inspect} is not supported by this Rigor build " \
                   "(Prism accepts #{floor} and newer). Set target_ruby to your project's Ruby version " \
                   "(>= #{floor}) — read it from Gemfile.lock's `RUBY VERSION` or .ruby-version. " \
                   "(Prism: #{e.message})",
          severity: :error,
          rule: "configuration-error",
          source_family: :builtin
        )
      end

      private

      # The run's per-file effect collections in sorted path order — the sequential half merged with the
      # pool's, exactly as {#file_dependencies} reconciles its two halves. Sorted, because the fold below
      # it must not depend on pool-completion order.
      def effect_collections
        effect_collections_by_path.sort_by { |path, _| path.to_s }.map(&:last)
      end

      # Editor mode § "Scope choice — option A". Under `buffer:` non-nil the per-file analysis emits
      # diagnostics ONLY for the buffer's logical path; the rest of `paths:` is consumed by the
      # project-wide pre-passes (synthetic methods, project-patched methods, plugin facts) but contributes
      # no per-file diagnostics. This is the v1 cut before a per-file diagnostic cache exists; option B
      # (full project + incremental cache) is queued.
      #
      # The buffer's logical path is added to the file list even if it's not under `paths:` — per design §
      # "Failure envelope": "--instead-of=Y with Y not under any paths: directory → treated as a valid
      # logical identity for the buffer".
      def target_files(expansion)
        files = expansion.fetch(:files)
        # ADR-46 slice 2 — restrict the analyzed set to the affected closure while the pre-pass (run
        # separately over `expansion`'s full file list) keeps the cross-file index complete.
        if @analyze_only
          # Editor mode option B (#146) — with BOTH set, the closure wins and the buffer is one member of it.
          # The logical path joins even when it is not on disk under `paths:` (design § "Failure envelope"),
          # the same allowance option A makes below.
          files = files.select { |path| @analyze_only.include?(path) }
          files |= [@buffer.logical_path] if @buffer && @analyze_only.include?(@buffer.logical_path)
          return files
        end
        return files if @buffer.nil?

        # Editor mode option A — no closure, so the buffer's single logical path IS the analyzed set.
        [@buffer.logical_path]
      end

      # Editor mode (`buffer:` non-nil) auto-flips the cache store to `read_only: true` so multiple
      # debounced editor invocations against the same project don't churn the on-disk cache or race on
      # schema-version writes. Cache reads continue unchanged; misses still run the producer block but the
      # result is not persisted. Per design doc § "Cache behaviour".
      def enforce_read_only_cache(cache_store, buffer)
        return cache_store if buffer.nil?
        return cache_store if cache_store.nil?
        return cache_store if cache_store.read_only?

        Cache::Store.new(root: cache_store.root, read_only: true)
      end

      # Wires the three responsibility collaborators. Called at the end of construction (after every state
      # ivar is seeded). The per-run varying state (the plugin registry, dependency-source / scanner
      # indexes, prepare-diagnostic snapshot, and the four end-of-pass snapshots) is reached through reader
      # procs so each collaborator observes the live ivar value at call time without a back-reference
      # cycle. The reporter accumulators and the {RunSnapshots} sink are shared mutable instances.
      def build_collaborators # rubocop:disable Metrics/MethodLength
        @pre_passes = ProjectPrePasses.new(
          configuration: @configuration, cache_store: @cache_store, buffer: @buffer,
          plugin_requirer: @plugin_requirer, pool_mode: -> { pool_mode? }
        )
        @pool_coordinator = PoolCoordinator.new(
          configuration: @configuration, cache_store: @cache_store, explain: @explain,
          workers: @workers, collect_stats: @collect_stats, buffer: @buffer,
          record_dependencies: @record_dependencies,
          environment_override: @environment_override,
          rbs_extended_reporter: @rbs_extended_reporter,
          boundary_cross_reporter: @boundary_cross_reporter,
          source_rbs_synthesis_reporter: @source_rbs_synthesis_reporter,
          snapshots: @snapshots,
          plugin_registry: -> { @plugin_registry },
          dependency_source_index: -> { @dependency_source_index },
          synthetic_method_index: -> { @synthetic_method_index },
          project_patched_methods: -> { @project_patched_methods },
          project_scope_seed: -> { project_scope_seed_tables },
          analyze_file: ->(path, environment) { analyze_file(path, environment) }
        )
        @diagnostic_aggregator = DiagnosticAggregator.new(
          configuration: @configuration,
          rbs_extended_reporter: @rbs_extended_reporter,
          boundary_cross_reporter: @boundary_cross_reporter,
          source_rbs_synthesis_reporter: @source_rbs_synthesis_reporter,
          plugin_registry: -> { @plugin_registry },
          dependency_source_index: -> { @dependency_source_index },
          pool_mode: -> { pool_mode? },
          cached_plugin_prepare_diagnostics: -> { @cached_plugin_prepare_diagnostics },
          pre_eval_diagnostics_from_scanner: -> { @pre_eval_diagnostics_from_scanner },
          synthesized_namespaces_snapshot: -> { @snapshots.synthesized_namespaces },
          quarantined_signatures_snapshot: -> { @snapshots.quarantined_signatures },
          env_build_failure_snapshot: -> { @snapshots.env_build_failure },
          conformance_results_snapshot: -> { @snapshots.conformance_results }
        )
      end

      # ADR-15 Phase 4b — pool mode is enabled when `@workers > 0`. Editor mode (`buffer:` non-nil)
      # silently overrides pool mode to sequential. The real decision lives on {PoolCoordinator}; the
      # predicate stays on the runner because `run_result_cacheable?` consults it (and a spec exercises it
      # via `send`).
      def pool_mode?
        @pool_coordinator.pool_mode?
      end

      # End-of-run telemetry. Walks the cached `class_decl_paths` snapshot (sequential mode: from the
      # coordinator's environment; pool mode: from the first worker's `:prepare` payload) and partitions
      # the RBS class universe into "project sig/" (paths under `signature_paths`) vs "bundled" (everything
      # else). Gem source-walk counts come from `dependency_source_index` which is already constructed
      # regardless of pool mode. Wall + RSS are single syscalls; total cost is bounded by the snapshot size
      # (~1000-2000 entries).
      def build_run_stats(wall_started_at:, expansion:)
        snapshot = @snapshots.class_decl_paths
        project_sig, bundled = RunStats.partition_classes(
          class_decl_paths: snapshot,
          signature_paths: @snapshots.signature_paths
        )
        RunStats.new(
          wall_seconds: Process.clock_gettime(Process::CLOCK_MONOTONIC) - wall_started_at,
          peak_rss_bytes: RunStats.peak_rss_bytes,
          target_files: expansion.fetch(:files).size,
          rbs_classes_total: snapshot.size,
          rbs_classes_project_sig: project_sig,
          rbs_classes_bundled: bundled,
          rbs_attribution_available: RunStats.attribution_available?(class_decl_paths: snapshot),
          gem_walk_classes: @dependency_source_index.class_to_gem.size,
          gem_walk_gems: @dependency_source_index.resolved_gems.size
        )
      end

      # ADR-7 § "Slice 5-A/5-B" — invokes every loaded plugin's per-file diagnostic emission hook
      # (`Plugin::Base#diagnostics_for_file`) and re-stamps the returned diagnostics with
      # `source_family: "plugin.<manifest.id>"` so plugin authors cannot accidentally publish under
      # another plugin's identifier or under `:builtin`. Plugin exceptions are isolated per ADR-2 § "Plugin
      # Trust and I/O Policy" — a raise from one plugin becomes a `:plugin_loader` `runtime-error`
      # diagnostic without affecting other plugins or the rest of the run.
      # ADR-52 WD1 — only the plugins that overrode `#diagnostics_for_file` or declared a `node_rule` are
      # visited (`contribution_index.for_file_diagnostics`); a skipped plugin's two hooks could only have
      # returned `[]`.
      def plugin_emitted_diagnostics(path, root, scope, node_results)
        return [] if @plugin_registry.empty?

        @plugin_registry.contribution_index.for_file_diagnostics.flat_map do |plugin|
          collect_plugin_diagnostics(plugin, path, root, scope, node_results[plugin])
        end
      end

      # ADR-52 WD4 + ADR-53 B4 — one engine-owned AST walk per file dispatches each node to every matching
      # (plugin, rule) AND drives the built-in node collectors (`node_collectors`), so the file is walked
      # once for both. The per-plugin results are bucketed in registry order so plugin emission stays
      # plugin-major (byte-identical with the old per-plugin walk); the collectors are populated in place
      # for `diagnose` to consume.
      #
      # When no plugin declares a node rule, the walk still runs to drive the collectors (the converged
      # path replaces the standalone `RuleWalk.run`); `node_collectors` nil means a caller that does not
      # need built-in collection from this walk.
      def node_rule_results_by_plugin(path, root, scope, node_collectors, scope_index)
        walk = @plugin_registry.node_rule_walk
        driver = node_collectors && CheckRules.node_collector_driver(node_collectors)
        return {}.compare_by_identity if walk.empty? && driver.nil?

        results = walk.diagnostics_for_file(
          path: path, scope: scope, root: root, collector_driver: driver
        )
        CheckRules.shadow_verify_converged_collectors(path, root, scope_index, node_collectors) if shadow_rule_walk?
        results.each_with_object({}.compare_by_identity) do |result, by_plugin|
          by_plugin[result.plugin] = result
        end
      end

      def shadow_rule_walk?
        ENV.fetch("RIGOR_SHADOW_RULE_WALK", nil)
      end

      def collect_plugin_diagnostics(plugin, path, root, scope, node_result)
        raw = Array(plugin.diagnostics_for_file(path: path, scope: scope, root: root))
        # A node-rule context/rule raise isolates the whole plugin's node-rule contribution, matching the
        # old combined per-plugin rescue (which discarded `diagnostics_for_file` output too).
        raise node_result.error if node_result&.error

        raw += node_result.diagnostics if node_result
        raw.map { |diagnostic| stamp_plugin_diagnostic(diagnostic, plugin.manifest.id) }
      rescue StandardError => e
        [plugin_runtime_error_diagnostic(path, plugin, e)]
      end

      def stamp_plugin_diagnostic(diagnostic, plugin_id)
        Diagnostic.new(
          path: diagnostic.path,
          line: diagnostic.line,
          column: diagnostic.column,
          message: diagnostic.message,
          severity: diagnostic.severity,
          rule: diagnostic.rule,
          source_family: "plugin.#{plugin_id}"
        )
      end

      def plugin_runtime_error_diagnostic(path, plugin, error)
        plugin_id = safe_plugin_id(plugin)
        Diagnostic.new(
          path: path,
          line: 1,
          column: 1,
          message: "plugin #{plugin_id.inspect} raised during diagnostics_for_file: " \
                   "#{error.class}: #{error.message}",
          severity: :error,
          rule: "runtime-error",
          source_family: :plugin_loader
        )
      end

      def safe_plugin_id(plugin)
        plugin.manifest.id
      rescue StandardError
        plugin.class.to_s
      end

      # Resolves the user-supplied path list into:
      # - `:files`  — the concrete `.rb` files to analyze.
      # - `:errors` — `Diagnostic` entries for each path that does not exist or is not a recognisable Ruby
      #   source.
      #
      # Surfacing path errors is a first-preview must-have: `rigor check ./does_not_exist.rb` previously
      # exited cleanly with no output, which silently masked typos.
      def expand_paths(paths)
        files = []
        bad = []
        Array(paths).each do |path|
          if File.directory?(path)
            files.concat(PathExpansion.directory_files(path, @configuration.exclude_patterns))
          # Editor-mode bypass: the buffer's logical path is treated as a real `.rb` file regardless of
          # on-disk presence — `parse_source` reads bytes from the buffer's physical path. Common case: LSP
          # client editing a brand-new file.
          elsif accept_as_ruby_file?(path)
            files << path
          elsif File.exist?(path)
            bad << [path, "not a Ruby file (expected `.rb` or a directory)"]
          else
            bad << [path, "no such file or directory"]
          end
        end
        { files: files, errors: path_expansion_errors(bad, any_files: files.any?) }
      end

      # A bad path *among valid ones* is a warn-and-skip — the run still does useful work, so `rigor check
      # app lib` with no `lib/` (the 20260620 field trial's strap case) analyses `app` instead of aborting
      # on exit 1. A bad path that leaves NOTHING to analyse stays an error so a lone typo (`rigor check
      # typo.rb`) is not silently masked (the regression the path-error check was added to catch in the
      # first place).
      def path_expansion_errors(bad, any_files:)
        severity = any_files ? :warning : :error
        suffix = any_files ? " (skipped)" : ""
        bad.map { |path, message| path_error(path, "#{message}#{suffix}", severity: severity) }
      end

      def accept_as_ruby_file?(path)
        (File.file?(path) && path.end_with?(".rb")) ||
          (@buffer && path == @buffer.logical_path) ||
          @in_memory_sources&.key?(path)
      end

      def path_error(path, message, severity: :error)
        Diagnostic.new(
          path: path,
          line: 1,
          column: 1,
          message: message,
          severity: severity
        )
      end

      # Reads + parses the source at `path`. Under editor mode (`@buffer` set) reads bytes from
      # `@buffer.physical_path` when `path` matches the logical binding, then parses with `filepath: path`
      # so Prism's location data carries the LOGICAL path. Non-binding paths go through the cheaper
      # `Prism.parse_file` codepath unchanged.
      def parse_source(path)
        if @in_memory_sources&.key?(path)
          return Prism.parse(@in_memory_sources[path], filepath: path, version: @configuration.target_ruby)
        end

        physical = @buffer ? @buffer.resolve(path) : path
        return Prism.parse_file(physical, version: @configuration.target_ruby) if physical == path

        Prism.parse(File.read(physical), filepath: path, version: @configuration.target_ruby)
      end

      # Seeds the cross-file project pre-pass indexes onto a fresh per-file scope: discovered classes, and
      # the ADR-24 def-node / superclass / included-module maps. Each is applied only when non-empty so a
      # runner constructed without the project pre-pass (e.g. a single-file probe) keeps an empty seed.
      def seed_project_scope(scope)
        tables = project_scope_seed_tables
        return scope if tables.empty?

        scope.with_discovery(scope.discovery.with(**tables))
      end

      # The cross-file pre-pass tables {#seed_project_scope} applies, as a plain Hash so the fork-pool path
      # can hand the same seed to its {WorkerSession} (whose per-file scopes would otherwise miss every
      # cross-file def — ADR-15 sequential-equivalence contract).
      #
      # Issue #260 — an opt-in `discovery_seed:` is the BASE of the result, so every table this run computed
      # for itself still wins. Under `prebuilt:` (the only caller that passes one today) the run computes
      # none, so the seed applies wholesale.
      def project_scope_seed_tables
        tables = discovery_seed_base
        # ADR-84 WD2 — the run-scope token rides the same seed so the fork/Ractor `WorkerSession` scopes
        # bucket identically to the sequential path.
        tables[:run_generation] = @run_generation if @run_generation
        tables[:discovered_classes] = @project_discovered_classes unless @project_discovered_classes.empty?
        tables[:discovered_def_nodes] = @project_discovered_def_nodes unless @project_discovered_def_nodes.empty?
        unless @project_discovered_singleton_def_nodes.empty?
          tables[:discovered_singleton_def_nodes] = @project_discovered_singleton_def_nodes
        end
        seed_def_source_tables(tables)
        unless @project_discovered_superclasses.empty?
          tables[:discovered_superclasses] = @project_discovered_superclasses
        end
        tables[:discovered_includes] = @project_discovered_includes unless @project_discovered_includes.empty?
        unless @project_discovered_method_visibilities.empty?
          tables[:discovered_method_visibilities] = @project_discovered_method_visibilities
        end
        tables[:discovered_methods] = @project_discovered_methods unless @project_discovered_methods.empty?
        seed_opt_in_pre_pass_tables(tables)
        seed_member_layout_tables(tables)
        # ADR-46 slice 1 — the class-declaration source map is read only by the ancestry accessors during
        # dependency recording, so seed it only when recording is on; a normal run never carries it.
        if @record_dependencies && !@project_discovered_class_sources.empty?
          tables[:discovered_class_sources] = @project_discovered_class_sources
        end
        tables
      end

      # Issue #260 — the mutable starting point {#project_scope_seed_tables} fills in: a copy of the opt-in
      # `discovery_seed:` when one was supplied, otherwise the empty Hash every other run has always started
      # from. Extracted so the seed costs {#project_scope_seed_tables} no branch of its complexity budget.
      def discovery_seed_base
        @discovery_seed ? @discovery_seed.dup : {}
      end

      # Seeds the two OPT-IN pre-pass tables — the ones an ordinary run leaves empty, so they are absent from
      # the seed entirely unless the project asked for them. Both ride this seed so a pooled `WorkerSession`
      # scope resolves identically to the sequential path (ADR-15 sequential equivalence).
      #
      # - ADR-67 WD6a `param_inferred_types`: the call-site parameter-inference table, populated only when the
      #   `parameter_inference:` gate ran the pre-pass.
      # - Issue #352 `in_source_constants`: the `pre_eval:` constant publication, populated only when the
      #   project lists `pre_eval:` files that declare publishable constants.
      #
      # Extracted to keep {#project_scope_seed_tables} under the complexity budget.
      def seed_opt_in_pre_pass_tables(tables)
        tables[:param_inferred_types] = @project_param_inferred_types unless @project_param_inferred_types.empty?
        return if @project_pre_eval_constants.empty?

        tables[:in_source_constants] = @project_pre_eval_constants
      end

      # ADR-46 — seed the instance + singleton `"path:line"` def-source tables (each only when non-empty).
      # Extracted to keep {#project_scope_seed_tables} under the complexity budget. The singleton table (slice 4
      # extension) rides the same seed so a pooled `WorkerSession` records singleton symbol edges identically.
      def seed_def_source_tables(tables)
        tables[:discovered_def_sources] = @project_discovered_def_sources unless @project_discovered_def_sources.empty?
        return if @project_discovered_singleton_def_sources.empty?

        tables[:discovered_singleton_def_sources] = @project_discovered_singleton_def_sources
      end

      # ADR-48 — seed the Data + Struct member-layout tables (each only when non-empty). Extracted to keep
      # {#project_scope_seed_tables} under the complexity budget.
      def seed_member_layout_tables(tables)
        tables[:data_member_layouts] = @project_data_member_layouts unless @project_data_member_layouts.empty?
        return if @project_struct_member_layouts.empty?

        tables[:struct_member_layouts] = @project_struct_member_layouts
      end

      # ADR-46 slice 1 — when dependency recording is enabled, wrap the per-file analysis so the cross-file
      # reads its inference makes are captured into `file_dependencies[path]`. Off by default: a normal run
      # calls the body directly and the instrumented `Scope` accessors short-circuit on
      # `DependencyRecorder.active? == false`. Recording is observational, so diagnostics are byte-identical
      # either way.
      def analyze_file(path, environment)
        return analyze_with_effects(path, environment) unless @record_dependencies

        diagnostics = nil
        record = DependencyRecorder.record_for(path) do
          diagnostics = analyze_with_effects(path, environment)
        end
        @file_dependencies[path] = record
        diagnostics
      end

      # ADR-103 WD13 — the effect-collection window, in the same shape as the dependency one and nested
      # inside it so a recording incremental run collects both. Off by default: `effects_enabled?` false
      # calls the body directly, {Effects::Collector.active?} stays false, and the recorder's sites on the
      # dispatch path short-circuit on one integer read.
      def analyze_with_effects(path, environment)
        return analyze_file_body(path, environment) unless @record_effects

        diagnostics = nil
        collection = Effects::Collector.collect_for(
          path, attribution: @effect_attribution, envelopes: effect_envelope_index(environment),
                plugin_facts: effect_plugin_facts
        ) do
          diagnostics = analyze_file_body(path, environment)
        end
        @file_effects[path] = collection
        diagnostics
      end

      # ADR-103 WD6 / #386 — the envelopes a call site may import as a `≤` bound, built once per process
      # over the first environment the analysis resolves and reused for every later file. A worker builds
      # its own from the same configuration and the same signature content ({WorkerSession}), so the two
      # agree without a channel to keep in sync.
      #
      # Memoised on the environment's identity rather than unconditionally: a run that resolves its
      # environment lazily hands `nil` to the first files, and an index built from `nil` would silently
      # pin the whole run to the strata a loader-less build can read.
      def effect_envelope_index(environment)
        return @effect_envelope_index if @effect_envelope_index && @effect_envelope_index_env.equal?(environment)

        @effect_envelope_index_env = environment
        @effect_envelope_index = Effects::EnvelopeIndex.build(
          configuration: @configuration, environment: environment, plugin_facts: effect_plugin_facts
        )
      end
      private :effect_envelope_index

      def analyze_file_body(path, environment) # rubocop:disable Metrics/MethodLength
        parse_result = parse_source(path)
        unless parse_result.errors.empty?
          return [] if ErbTemplateDetector.template?(parse_result)

          return parse_diagnostics(path, parse_result)
        end

        # ADR-103 WD13 — hand the effect collector the root the typer is about to walk, so its per-def
        # scan runs over exactly what was typed. Guarded inside the recorder rather than by `active?`: this
        # is a per-FILE site, so one `Thread.current` read is already nothing. The per-dispatch site in
        # `ExpressionTyper#call_type_for` is the one that pays for the integer fast path.
        Effects::Collector.record_root(parse_result.value)
        scope = seed_project_scope(Scope.empty(environment: environment, source_path: path))
        # ADR-24 slice 4a/4 — record unresolved implicit-self calls during the typing pass ONLY (not
        # CheckRules, whose own `type_of` queries would otherwise re-trigger the choke-point).
        # `self_call_misses` feeds the `call.self-undefined-method` collector; the recorder is inert unless
        # the rule is active or `record_self_calls:` opted in.
        index = nil
        self_call_record = with_self_call_recording(path) do
          index = Inference::ScopeIndexer.index(parse_result.value, default_scope: scope)
        end
        self_call_misses = self_call_record ? self_call_record.calls : []
        diagnostics = rule_and_plugin_diagnostics(path, parse_result, scope, index, self_call_misses)
        diagnostics + explain_diagnostics(path, parse_result.value, scope)
      rescue Errno::ENOENT => e
        [
          Diagnostic.new(
            path: path,
            line: 1,
            column: 1,
            message: e.message,
            severity: :error
          )
        ]
      rescue StandardError => e
        [
          Diagnostic.new(
            path: path,
            line: 1,
            column: 1,
            message: "internal analyzer error: #{e.class}: #{e.message}",
            severity: :error
          )
        ]
      end

      # ADR-53 B4 — the built-in node collectors and the plugin node rules share ONE traversal of the file.
      # The collectors are built here (they need the completed `index`) and populated by the converged
      # plugin walk; `node_results` carries the per-plugin node-rule output. Both the built-in `diagnose`
      # output and the plugin diagnostics are then built from that single walk's results.
      def rule_and_plugin_diagnostics(path, parse_result, scope, index, self_call_misses)
        root = parse_result.value
        node_collectors = CheckRules.build_node_collectors(path, index)
        node_results = node_rule_results_by_plugin(path, root, scope, node_collectors, index)
        diagnostics = CheckRules.diagnose(
          path: path,
          root: root,
          scope_index: index,
          self_call_misses: self_call_misses,
          comments: parse_result.comments,
          disabled_rules: @configuration.disabled_rules,
          node_collectors: node_collectors
        )
        diagnostics + plugin_emitted_diagnostics(path, root, scope, node_results)
      end

      # ADR-24 slice 4a — runs `block` (the typing pass) with the self-call recorder active when either
      # the test-only `record_self_calls:` flag is set or the `call.self-undefined-method` rule resolves to
      # a firing severity. Returns the frozen {SelfCallResolutionRecorder::Record}, or nil when recording is
      # inactive (the common path — one integer read).
      def with_self_call_recording(path, &)
        unless self_call_recording_active?
          yield
          return nil
        end

        record = SelfCallResolutionRecorder.record_for(path, &)
        @unresolved_self_calls[path] = record
        record
      end

      def self_call_recording_active?
        @record_self_calls || self_undefined_rule_active?
      end

      # Memoised: the rule fires only when its resolved severity is not `:off` and it is not in `disable:`.
      # Default profiles map it to `:off`, so a normal run never activates the recorder (pending the
      # external WD4 corpus FP gate — see ADR-24 § "Slice 4"); a project opts in via `severity_overrides:`.
      def self_undefined_rule_active?
        return @self_undefined_rule_active unless @self_undefined_rule_active.nil?

        rule = CheckRules::RULE_SELF_UNDEFINED_METHOD
        @self_undefined_rule_active =
          if @configuration.disabled_rules.include?(rule) || @configuration.disabled_rules.include?("call")
            false
          else
            Configuration::SeverityProfile.resolve(
              rule: rule, authored_severity: :warning,
              profile: @configuration.severity_profile, overrides: @configuration.severity_overrides,
              bleeding_edge_overrides: @configuration.bleeding_edge_severity_overrides
            ) != :off
          end
      end

      # v0.0.2 #10 — fail-soft fallback explanation. When `--explain` is set the runner additionally walks
      # the file with `Rigor::Inference::CoverageScanner` and emits one `:info` diagnostic per
      # directly-unrecognized node, naming the node class and the type the engine fell back to. The
      # CoverageScanner is the canonical "first-event-per-node" probe: it already filters out pass-through
      # wrappers (`ProgramNode`, `StatementsNode`, `ParenthesesNode`) so the explain stream is attributable
      # to the leaf node that actually triggered the fallback.
      def explain_diagnostics(path, root, scope)
        return [] unless @explain

        result = Inference::CoverageScanner.new(scope: scope).scan(root)
        result.events.map { |event| explain_diagnostic(path, event) }
      end

      def explain_diagnostic(path, event)
        location = event.location
        line = location ? location.start_line : 1
        column = location ? location.start_column + 1 : 1
        Diagnostic.new(
          path: path,
          line: line,
          column: column,
          message: "fail-soft fallback at #{event.node_class}: #{event.inner_type.describe(:short)}",
          severity: :info,
          rule: "fallback"
        )
      end

      def parse_diagnostics(path, parse_result)
        parse_result.errors.map do |error|
          location = error.location
          Diagnostic.new(
            path: path,
            line: location.start_line,
            column: location.start_column + 1,
            message: error.message,
            severity: :error
          )
        end
      end
    end
  end
end
