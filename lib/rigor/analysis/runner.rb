# frozen_string_literal: true

require "digest"
require "prism"
require "tmpdir"

require_relative "../environment"
require_relative "../scope"
require_relative "../cache/store"
require_relative "../cache/rbs_descriptor"
require_relative "../plugin"
require_relative "../plugin/source_rbs_synthesis_reporter"
require_relative "../rbs_extended/reporter"
require_relative "../rbs_extended/conformance_checker"
require_relative "../reflection"
require_relative "../type/combinator"
require_relative "../inference/coverage_scanner"
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

module Rigor
  module Analysis
    class Runner # rubocop:disable Metrics/ClassLength
      RUBY_GLOB = "**/*.rb"
      DEFAULT_CACHE_ROOT = ".rigor/cache"

      attr_reader :cache_store, :plugin_registry, :dependency_source_index,
                  :rbs_extended_reporter, :boundary_cross_reporter, :file_dependencies,
                  :analyzed_files, :unresolved_self_calls

      # @param configuration [Rigor::Configuration]
      # @param explain [Boolean] surface fail-soft fallback events
      #   as `:info` diagnostics.
      # @param cache_store [Rigor::Cache::Store, nil] the persistent
      #   cache the runner exposes to producers (`RbsConstantTable`
      #   and successors). Pass `nil` to disable caching for this
      #   run; the CLI's `--no-cache` flag wires `nil` through.
      #   v0.0.9 group A slice 1 introduces the surface; later
      #   slices route real producers through it.
      # @param workers [Integer] ADR-15 Phase 4b — when greater
      #   than zero, per-file analysis dispatches across a pool of
      #   N Ractor workers built around {WorkerSession}. Default
      #   `0` keeps the sequential code path bit-for-bit
      #   unchanged. Phase 4c will wire the CLI / `.rigor.yml`
      #   surface that produces non-zero values; this slice
      #   leaves the parameter as a programmatic opt-in only.
      # @param collect_stats [Boolean] when true (default), `#run`
      #   builds a {RunStats} summary exposed via `result.stats`
      #   — this forces the RBS env build at end-of-run so the
      #   `class_decl_paths` snapshot has real source attribution.
      #   Set to false to skip the stats summary entirely; the
      #   CLI's `--no-stats` threads `false` through to keep
      #   trivial-fixture runs from warming `.rigor/cache`.
      # @param prebuilt [Rigor::Analysis::ProjectScan, nil] when
      #   supplied, the runner adopts the pre-built plugin
      #   registry / dependency-source index / scanner outputs
      #   from the snapshot and skips the per-call pre-passes
      #   that produce them. Used by long-lived integrations
      #   (`Rigor::LanguageServer::ProjectContext`) to keep
      #   per-buffer requests fast — scanners walk the project
      #   once per generation rather than once per request, and
      #   plugin `#prepare` runs once per generation rather than
      #   once per request. Watched-file invalidation is the
      #   owner's responsibility; the runner trusts the snapshot
      #   it was given.
      # @param environment [Rigor::Environment, nil] opt-in
      #   Environment override. When supplied, sequential mode uses
      #   the provided env instance in `#analyze_files` instead of
      #   building a fresh one via `Environment.for_project`, and
      #   attaches the runner's per-run reporter pair onto the
      #   env's mutable `Reporters` slot via
      #   `Environment#attach_reporters!`. Long-lived consumers
      #   (LSP `ProjectContext`) pass a shared env so per-publish
      #   work doesn't repeat the `Environment.for_project` build
      #   (bundler / lockfile / collection discovery, RbsLoader
      #   construction). Pool mode ignores the override — each
      #   worker continues to build its own Environment.
      def initialize(configuration:, explain: false, # rubocop:disable Metrics/ParameterLists,Metrics/AbcSize,Metrics/MethodLength
                     cache_store: Cache::Store.new(root: DEFAULT_CACHE_ROOT),
                     plugin_requirer: nil, workers: 0, collect_stats: true,
                     buffer: nil, prebuilt: nil, environment: nil,
                     record_dependencies: false, record_self_calls: false, analyze_only: nil)
        @configuration = configuration
        @explain = explain
        @cache_store = enforce_read_only_cache(cache_store, buffer)
        @plugin_requirer = plugin_requirer
        @workers = workers
        @collect_stats = collect_stats
        @buffer = buffer
        @prebuilt = prebuilt
        @environment_override = environment
        # ADR-46 slice 1 — opt-in cross-file dependency recording. Off by
        # default; when true, `analyze_file` records each file's
        # cross-file reads into `file_dependencies` (the incremental
        # cache, a later slice, consumes them).
        @record_dependencies = record_dependencies
        # ADR-24 slice 4a — opt-in unresolved-implicit-self-call recording.
        # Off by default; when true, `analyze_file` activates the engine
        # choke-point recorder and collects each file's misses into
        # `unresolved_self_calls` (a later closed-class-gated rule consumes
        # them). Purely observational — diagnostics are byte-identical.
        @record_self_calls = record_self_calls
        @unresolved_self_calls = {}
        # Memoised activation decision for the `call.self-undefined-method`
        # rule (nil = not yet computed). See `self_undefined_rule_active?`.
        @self_undefined_rule_active = nil
        @analyzed_files = [].freeze
        # In-memory source map for `#run_source` — `{ logical_path => source
        # String }`. When set, `parse_source` reads bytes from here instead
        # of disk and `expand_paths` accepts the (possibly non-existent)
        # logical path. nil on a normal disk-backed run.
        @in_memory_sources = nil
        # ADR-46 slice 2 — the subset-analysis hook. When set (a collection
        # of paths), the whole-project pre-pass still runs over every file
        # (so the cross-file index is complete), but only files in this set
        # are analyzed for diagnostics — the body tier re-analyses the
        # affected closure and serves the rest from the per-file cache.
        # `nil` (the default) analyzes everything.
        @analyze_only = analyze_only && Set.new(analyze_only)
        @file_dependencies = {}
        @plugin_registry = Plugin::Registry::EMPTY
        @dependency_source_index = DependencySourceInference::Index::EMPTY
        @rbs_extended_reporter = RbsExtended::Reporter.new
        @boundary_cross_reporter = DependencySourceInference::BoundaryCrossReporter.new
        @source_rbs_synthesis_reporter = Plugin::SourceRbsSynthesisReporter.new
        # `#run` resets these for each invocation; pre-seed them to
        # empty containers so `build_run_stats` / `pre_file_diagnostics`
        # (private, called only from `#run`) can read them without
        # nil-guards. Kept inline (not a helper) so the engine's own
        # flow analysis sees the ivars established in the constructor.
        @class_decl_paths_snapshot = {}.freeze
        @signature_paths_snapshot = [].freeze
        @synthesized_namespaces_snapshot = [].freeze
        # `rigor:v1:conforms-to` results, snapshotted from the
        # per-run RBS env in `analyze_files_sequentially` (gated on
        # the project declaring `signature_paths:`) and drained by
        # `conforms_to_diagnostics`. Inline default per the comment
        # above so the engine's own flow analysis sees it seeded.
        @conformance_results_snapshot = [].freeze
        @cached_plugin_prepare_diagnostics = [].freeze
        @project_discovered_classes = {}.freeze
        @project_discovered_def_nodes = {}.freeze
        @project_discovered_def_sources = {}.freeze
        @project_discovered_superclasses = {}.freeze
        @project_discovered_includes = {}.freeze
        @project_discovered_class_sources = {}.freeze
        @project_discovered_method_visibilities = {}.freeze
        @project_discovered_methods = {}.freeze
        @project_data_member_layouts = {}.freeze
      end

      # ADR-pending editor mode — present when the runner is wired
      # for the `--tmp-file` / `--instead-of` buffer-binding shape
      # (`docs/design/20260516-editor-mode.md`). Nil for normal
      # project runs.
      attr_reader :buffer

      # Walks every Ruby file under `paths`, parses it, builds a
      # per-node scope index through
      # `Rigor::Inference::ScopeIndexer`, and runs the
      # `Rigor::Analysis::CheckRules` catalogue over it. Returns
      # a `Rigor::Analysis::Result` aggregating every produced
      # diagnostic plus any Prism parse errors. The Environment
      # is built once at run start through `Environment.for_project`
      # so all files share the same RBS load.
      def run(paths = @configuration.paths)
        Inference::MethodDispatcher::FileFolding.fold_platform_specific_paths =
          @configuration.fold_platform_specific_paths

        wall_started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        target_ruby_error = validate_target_ruby
        return Result.new(diagnostics: [target_ruby_error]) if target_ruby_error

        expansion = expand_paths(paths)
        @class_decl_paths_snapshot = {}.freeze
        @signature_paths_snapshot = []
        @synthesized_namespaces_snapshot = []
        @conformance_results_snapshot = []

        if @prebuilt
          adopt_prebuilt_project_scan(@prebuilt)
        else
          run_project_pre_passes(expansion: expansion)
        end

        diagnostics = compute_run_diagnostics(expansion)

        Result.new(
          diagnostics: apply_severity_profile(diagnostics),
          stats: stats_for_run(wall_started_at: wall_started_at, expansion: expansion)
        )
      end

      # Analyze a single source String in memory, without writing it to
      # disk — a clean entry point for embedders (LSP / editor mode) and a
      # faster spec path than the per-call tmpdir + chdir. The source is
      # bound to `path` (purely a logical identity carried in diagnostic
      # locations; it need not exist on disk). The full run machinery still
      # runs — environment build, plugin `prepare`, severity profile — so
      # the result matches a one-file disk run; only the cross-file project
      # pre-pass is empty (there is one file, and the per-file indexer
      # self-discovers its own classes / defs).
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

      # ADR-46 — the project file set that a run over `paths` would
      # analyze, computed by globbing only (no RBS environment build), so
      # the incremental fingerprint can be derived cheaply on the warm path
      # before deciding whether to build the env at all.
      def analysis_file_set(paths = @configuration.paths)
        expand_paths(paths).fetch(:files)
      end

      # ADR-46 §2 — inverts {#file_dependencies} into the reverse edge the
      # incremental step walks: `dependents[X] = { A : A read a
      # declaration / body from X }`. On an edit to X, the body tier
      # (slice 2) re-analyses `{X} ∪ dependents[X]` and serves every other
      # file from the per-file cache. Built on demand from the recorded
      # `sources` sets (so it reflects whatever `analyze_file` captured —
      # empty unless the runner was constructed with
      # `record_dependencies: true`). The negative (`missing`) edges are
      # NOT inverted here: they feed the structural tier (slice 3), which
      # re-checks a consumer when a name it looked up and did not resolve
      # later appears.
      def file_dependents
        Incremental.invert(@file_dependencies.transform_values(&:sources))
      end

      # ADR-46 slice 4 — per-symbol body fingerprints, computed from the
      # project pre-pass def index. Returns a frozen hash of the form:
      #   { "path/to/file.rb" => { "ClassName#method" => sha256_hex, … }, … }
      # Used by {Analysis::IncrementalSession} to detect which symbols in a
      # changed file actually changed bodies, so only callers of those
      # specific symbols are re-checked. Only meaningful after a run that
      # populated `@project_discovered_def_nodes` (i.e. any full or subset
      # analysis); returns an empty frozen hash before the first run.
      def symbol_fingerprints
        result = Hash.new { |h, k| h[k] = {} }
        @project_discovered_def_sources.each do |class_name, methods|
          methods.each do |method_sym, path_line|
            path = path_line.split(":", 2).first
            node = @project_discovered_def_nodes.dig(class_name, method_sym)
            next unless node

            result[path]["#{class_name}##{method_sym}"] =
              Digest::SHA256.hexdigest(node.location.slice)
          end
        end
        result.transform_values(&:freeze).freeze
      end

      # ADR-46 slice 3 — per-file set of the qualified class/module names
      # declared in that file. Used to detect a class that *appeared* in an
      # edit so a subclass whose ancestor was previously undefined (and so
      # recorded a negative class edge) is re-checked. Inverts the project
      # class-source attribution (class → declaring files).
      def class_declarations
        result = Hash.new { |hash, key| hash[key] = Set.new }
        @project_discovered_class_sources.each do |class_name, files|
          files.each { |file| result[file] << class_name }
        end
        result.transform_values(&:freeze).freeze
      end

      # ADR-45 — unchanged-project fast path. Serves the whole run's
      # (pre-severity-profile) diagnostics from one record-and-validate
      # cache entry when every file the previous run read is unchanged,
      # skipping the dominant per-file inference. The dependency set is
      # collected AFTER the run (so it captures files the plugins read
      # mid-analysis, e.g. a Pundit policy) and re-validated on the next
      # run; the entry is keyed on the inputs known up front (config, gem
      # / engine versions, analyzed-path set).
      def compute_run_diagnostics(expansion)
        @run_served_from_cache = false
        return assemble_run_diagnostics(expansion) unless run_result_cacheable?

        environment = resolve_sequential_environment(source_files: target_files(expansion))
        rbs_descriptor = environment&.rbs_loader ? Cache::RbsDescriptor.build(environment.rbs_loader) : Cache::Descriptor.new
        key_descriptor = run_key_descriptor(expansion, rbs_descriptor)
        return assemble_run_diagnostics(expansion, environment: environment) if key_descriptor.nil?

        computed = false
        diagnostics = @cache_store.fetch_or_validate(
          producer_id: "analysis.run-diagnostics", key_descriptor: key_descriptor
        ) do
          computed = true
          diags = assemble_run_diagnostics(expansion, environment: environment)
          [diags, run_dependency_descriptor(expansion, rbs_descriptor)]
        end
        @run_served_from_cache = !computed
        diagnostics
      rescue StandardError
        # The result cache must never break a run. If anything in the
        # cache path fails, fall back to a direct, uncached analysis.
        @run_served_from_cache = false
        assemble_run_diagnostics(expansion)
      end

      def assemble_run_diagnostics(expansion, environment: nil)
        diagnostics = pre_file_diagnostics(expansion)
        # ADR-46 — record which project files this run actually analyzed
        # (the `analyze_only` subset, or all of them). The incremental
        # orchestrator serves every analyzed-but-not-affected file from the
        # per-file cache, so it needs the full analyzed set to subtract the
        # affected closure from.
        targets = target_files(expansion)
        @analyzed_files = targets
        diagnostics += analyze_files(targets, environment: environment)
        diagnostics += rbs_synthesized_namespace_diagnostics
        diagnostics += conforms_to_diagnostics
        diagnostics += rbs_extended_reporter_diagnostics
        diagnostics += boundary_cross_diagnostics
        diagnostics + source_rbs_synthesis_diagnostics
      end

      # A cache hit skipped the analysis, so the per-run stats (wall
      # split, RBS-class counts, …) were never gathered — report none
      # rather than the stale snapshot defaults.
      def stats_for_run(wall_started_at:, expansion:)
        return nil unless @collect_stats
        return nil if @run_served_from_cache

        build_run_stats(wall_started_at: wall_started_at, expansion: expansion)
      end

      # Cacheable only for a full sequential project run with a writable
      # cache and no per-buffer / prebuilt override — every other mode has
      # a different result identity (pool workers read in separate
      # processes; editor mode is per-buffer; prebuilt is the LSP path).
      def run_result_cacheable?
        !@cache_store.nil? && !@cache_store.read_only? &&
          @buffer.nil? && @prebuilt.nil? && !pool_mode?
      end

      # Stable cache key inputs — known before the run: a digest of the
      # resolved configuration, the engine + rbs versions + `--explain`,
      # and the analyzed-path SET (adding/removing a file changes the
      # key; editing one is caught by dependency validation). nil disables
      # the cache for this run rather than risking a malformed key.
      def run_key_descriptor(expansion, rbs_descriptor)
        Cache::Descriptor.new(
          gems: rbs_descriptor.gems,
          configs: rbs_descriptor.configs + [
            config_hash_entry("configuration", Marshal.dump(@configuration.to_h)),
            config_hash_entry("engine", "#{Rigor::VERSION}:#{Cache::Descriptor::SCHEMA_VERSION}:#{@explain}"),
            config_hash_entry("paths", expansion.fetch(:files).sort.join("\n"))
          ]
        )
      rescue StandardError
        nil
      end

      # Files the run actually depended on, collected AFTER it ran:
      # every analyzed file, every RBS `sig` file (`rbs_descriptor.files`),
      # and every file each plugin read (complete post-run, so reads made
      # mid-analysis are included). Re-digested on the next run by
      # {Descriptor#fresh?}.
      def run_dependency_descriptor(expansion, rbs_descriptor)
        entries = analyzed_file_entries(expansion) + rbs_descriptor.files
        @plugin_registry.plugins.each do |plugin|
          # Read the boundary WITHOUT triggering its lazy `@io_boundary ||=`
          # initializer: plugin instances are frozen after the run, and a
          # plugin that never built a boundary read no files through it, so
          # it contributes no dependencies.
          boundary = plugin.instance_variable_get(:@io_boundary)
          entries.concat(boundary.cache_descriptor.files) if boundary
        end
        Cache::Descriptor.new(files: entries)
      end

      def analyzed_file_entries(expansion)
        expansion.fetch(:files).map do |path|
          physical = @buffer ? @buffer.resolve(path) : path
          Cache::Descriptor::FileEntry.new(
            path: physical, comparator: :digest, value: Digest::SHA256.file(physical).hexdigest
          )
        end
      end

      def config_hash_entry(key, payload)
        Cache::Descriptor::ConfigEntry.new(key: key, value_hash: Digest::SHA256.hexdigest(payload))
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
        run_project_pre_passes(expansion: expansion)
        ProjectScan.new(
          plugin_registry: @plugin_registry,
          dependency_source_index: @dependency_source_index,
          synthetic_method_index: @synthetic_method_index,
          project_patched_methods: @project_patched_methods,
          plugin_prepare_diagnostics: @cached_plugin_prepare_diagnostics.dup.freeze,
          pre_eval_diagnostics: @pre_eval_diagnostics_from_scanner.dup.freeze
        )
      end

      # Internal: drives every project-wide pre-pass and stores
      # the results on instance variables in the order the
      # downstream `#run` body expects. Extracted so
      # `#prepare_project_scan` and the prebuilt-less `#run` path
      # share one implementation.
      def run_project_pre_passes(expansion:) # rubocop:disable Metrics/AbcSize
        @plugin_registry = load_plugins
        @dependency_source_index = DependencySourceInference::Builder.build(@configuration.dependencies)
        # ADR-18 slice 3 — plugin prepare MUST run before the
        # synthetic-method scanner so cross-plugin facts
        # (`:dry_type_aliases` etc.) are already published when
        # the scanner resolves Tier C `returns_from_arg:`
        # lookups. The diagnostics produced by prepare are
        # captured here so `pre_file_diagnostics` can re-emit
        # them in the existing order without invoking prepare
        # twice. Pool mode still re-runs prepare per worker
        # (workers don't see this early invocation), preserving
        # the existing Phase 4b contract.
        @cached_plugin_prepare_diagnostics =
          pool_mode? ? [] : plugin_prepare_diagnostics
        # ADR-16 slice 2b — Tier C pre-pass. Built once per run
        # against the resolved file set + the loaded plugin
        # registry's `heredoc_templates` so synthetic methods are
        # visible cross-file when per-file inference dispatches.
        @synthetic_method_index = Inference::SyntheticMethodScanner.scan(
          plugin_registry: @plugin_registry,
          paths: expansion.fetch(:files),
          environment: nil,
          fact_store: shared_fact_store,
          buffer: @buffer
        )
        # ADR-17 slice 2 — pre-eval pre-pass. Built once per run
        # from the `pre_eval:` entries that exist on disk
        # (slice-1's `pre-eval.file-not-found` `:error` already
        # surfaced any missing entries; the scanner skips them
        # here). The resulting {ProjectPatchedMethods} registry
        # is consulted by the dispatcher tier between plugins
        # and dependency-source inference so project-side
        # patches resolve cross-file.
        existing_pre_eval = @configuration.pre_eval.select { |path| File.file?(path) }
        pre_eval_outcome = Inference::ProjectPatchedScanner.scan(existing_pre_eval, buffer: @buffer)
        @project_patched_methods = pre_eval_outcome.registry
        @pre_eval_diagnostics_from_scanner = pre_eval_outcome.diagnostics
        # Cross-file class discovery — walks every project file
        # for `class Foo` / `module Bar` declarations so a
        # `Foo.method_call` receiver in one file resolves a
        # `class Foo` declared in a sibling file. Without this
        # pre-pass each file's `discovered_classes` was per-file
        # only, and lexical lookup fell back to stdlib `::Foo`
        # for any user class shadowing a stdlib name (e.g.
        # `Google::Cloud::Storage::File`). Cost is one extra
        # parse pass over the project; small projects pay
        # tens of ms, larger projects ~1s. Future optimisation
        # can share parses with the existing scanner passes.
        @project_discovered_classes =
          Inference::ScopeIndexer.discovered_classes_for_paths(expansion.fetch(:files), buffer: @buffer)
        # ADR-24 slice 2 — cross-file def-node + class->superclass
        # index so an implicit-self call inside a subclass
        # resolves a superclass `def` declared in a sibling
        # file. One extra parse pass over the project; shares
        # the cost profile of the class-discovery pass above.
        def_index =
          Inference::ScopeIndexer.discovered_def_index_for_paths(expansion.fetch(:files), buffer: @buffer)
        @project_discovered_def_nodes = def_index.fetch(:def_nodes)
        @project_discovered_def_sources = def_index.fetch(:def_sources)
        @project_discovered_superclasses = def_index.fetch(:superclasses)
        @project_discovered_includes = def_index.fetch(:includes)
        @project_discovered_class_sources = def_index.fetch(:class_sources)
        @project_discovered_method_visibilities = def_index.fetch(:method_visibilities)
        @project_discovered_methods = def_index.fetch(:methods)
        @project_data_member_layouts = def_index.fetch(:data_member_layouts)
      end

      # Internal: adopts a frozen {ProjectScan} snapshot supplied
      # to `Runner.new(prebuilt: ...)` by storing each slot on
      # the runner's ivar surface, mirroring what
      # `run_project_pre_passes` would have produced.
      def adopt_prebuilt_project_scan(scan)
        @plugin_registry = scan.plugin_registry
        @dependency_source_index = scan.dependency_source_index
        @synthetic_method_index = scan.synthetic_method_index
        @project_patched_methods = scan.project_patched_methods
        @cached_plugin_prepare_diagnostics = scan.plugin_prepare_diagnostics
        @pre_eval_diagnostics_from_scanner = scan.pre_eval_diagnostics
      end
      private :run_project_pre_passes, :adopt_prebuilt_project_scan

      # ADR-15 Phase 4b — routes per-file analysis to either the
      # sequential coordinator-side Environment (legacy path,
      # default) or a Ractor worker pool built around
      # {WorkerSession} (opt-in via `workers:`). The sequential
      # path is bit-for-bit unchanged from v0.1.4 / earlier; the
      # pool path is the substrate exercised by phase 4c when
      # `RIGOR_RACTOR_WORKERS` / `.rigor.yml` `parallel.workers:`
      # is wired.
      #
      # Sequential mode also snapshots `class_decl_paths` from the
      # local environment after the per-file loop completes so
      # `RunStats` can attribute the RBS class universe between
      # project-sig and bundled sources. The env stays a LOCAL
      # variable (not an ivar) so it goes GC-eligible when the
      # method returns — holding it as long-lived state added
      # memory pressure that surfaced as a Bus Error during the
      # spec suite under Ruby 4.0 + rbs 4.0.2.
      def analyze_files(files, environment: nil)
        return [] if files.empty?
        return dispatch_pool(files) if pool_mode?

        analyze_files_sequentially(files, environment || resolve_sequential_environment(source_files: files))
      end

      def analyze_files_sequentially(files, environment)
        # Snapshot the small synthesized-namespace name list (NOT the
        # env — see the method comment) so #run can surface the
        # malformed-RBS `:info` diagnostic without rebuilding the env.
        # Gated on the project actually declaring `signature_paths:`:
        # synthesis only matters for the project's own RBS, and
        # `#synthesized_namespaces` forces the (otherwise-lazy) RBS env
        # to build — doing so when there is no project sig set would
        # warm `.rigor/cache` on a bare `--no-stats` run.
        @synthesized_namespaces_snapshot =
          project_signature_paths? ? (environment.rbs_loader&.synthesized_namespaces || []) : []
        # `rigor:v1:conforms-to` lives only in the project's own
        # `signature_paths:` RBS, so gate the scan the same way and
        # reuse the already-built env (no extra RBS load).
        @conformance_results_snapshot =
          project_signature_paths? ? RbsExtended::ConformanceChecker.scan(environment.rbs_loader) : []
        result = files.flat_map { |path| analyze_file(path, environment) }
        if @collect_stats
          loader = environment.rbs_loader
          @class_decl_paths_snapshot = loader&.class_decl_paths || {}.freeze
          @signature_paths_snapshot = loader&.signature_paths || [].freeze
        end
        result
      end

      # Sequential-mode environment resolver. Returns the supplied
      # `environment:` override (with the runner's fresh per-run
      # reporter pair attached so dispatcher events route to THIS
      # runner's diagnostics) when present; otherwise builds a
      # fresh Environment per-call via {#build_runner_environment}
      # — preserving the pre-override behaviour bit-for-bit.
      def resolve_sequential_environment(source_files: [])
        return build_runner_environment(source_files: source_files) unless @environment_override

        @environment_override.attach_reporters!(
          rbs_extended_reporter: @rbs_extended_reporter,
          boundary_cross_reporter: @boundary_cross_reporter
        )
        @environment_override
      end
      private :resolve_sequential_environment

      # Pre-file diagnostic streams that fire once per run rather
      # than per analyzed file: plugin load / prepare envelopes,
      # the ADR-10 dependency-source resolution surface, and the
      # `expand_paths` errors for `paths:` entries that don't
      # exist or aren't `.rb`. Aggregated here so `#run` stays
      # under the ABC budget.
      #
      # ADR-15 Phase 4b — `plugin_prepare_diagnostics` runs on
      # the coordinator's plugin registry under sequential mode;
      # under pool mode each worker re-runs `prepare` against
      # its own plugin instances, so the pool path drains the
      # first worker's prepare-diagnostic snapshot into the
      # aggregated diagnostic stream instead (see
      # {#analyze_files_in_pool}). Skipping the coordinator
      # prepare in pool mode avoids double-running `#prepare`
      # against the coordinator-side plugin instances (which
      # the pool path never consults for per-file analysis).
      def pre_file_diagnostics(expansion)
        # ADR-18 slice 3 — prepare diagnostics are captured
        # earlier in #run (before the synthetic-method scanner)
        # so cross-plugin facts are available to the scanner.
        # We re-surface the captured diagnostics here so the
        # existing pre_file_diagnostics ordering is preserved.
        prepare = pool_mode? ? [] : @cached_plugin_prepare_diagnostics
        plugin_load_diagnostics +
          prepare +
          pre_eval_diagnostics +
          dependency_source_diagnostics +
          dependency_source_budget_diagnostics +
          dependency_source_config_conflict_diagnostics +
          rbs_coverage_diagnostics +
          expansion.fetch(:errors)
      end

      # Returns the per-run shared `Plugin::FactStore` instance.
      # All loaded plugins share this store through their
      # respective `Plugin::Services` (the same instance is
      # threaded by `Plugin::Loader.load`). Returns `nil` when
      # no plugins are loaded.
      def shared_fact_store
        return nil if @plugin_registry.nil? || @plugin_registry.empty?

        @plugin_registry.plugins.first&.services&.fact_store
      end

      # ADR-17 slice 1 — surface a `:error` diagnostic for each
      # `pre_eval:` entry whose resolved path doesn't exist on
      # disk. Loud failure mode (`:error`, not `:warning`):
      # a missing pre_eval path is a configuration mistake the
      # user must fix before analysis is meaningful.
      #
      # Slice 2 adds the `:warning` `pre-eval.parse-error`
      # stream from the pre-pass scanner — accumulated as
      # `@pre_eval_diagnostics_from_scanner` during {#run} and
      # merged here so both diagnostics flow through the same
      # severity / ordering pipeline.
      def pre_eval_diagnostics
        not_found = @configuration.pre_eval.filter_map do |path|
          next if File.file?(path)

          Diagnostic.new(
            path: ".rigor.yml", line: 1, column: 1,
            message: "pre_eval entry not found: #{path.inspect}. " \
                     "Pre-evaluation requires the file to exist on disk; remove the entry " \
                     "or create the file before re-running analysis.",
            severity: :error,
            rule: "pre-eval.file-not-found",
            source_family: :builtin
          )
        end
        not_found + Array(@pre_eval_diagnostics_from_scanner).map { |hash| diagnostic_from_hash(hash) }
      end

      def diagnostic_from_hash(hash)
        Diagnostic.new(
          path: hash.fetch(:path), line: hash.fetch(:line), column: hash.fetch(:column),
          message: hash.fetch(:message), severity: hash.fetch(:severity),
          rule: hash.fetch(:rule), source_family: :builtin
        )
      end

      # `target_ruby` flows through to Prism's `version:` option.
      # Prism enforces the supported range and raises
      # `ArgumentError` for versions it does not recognise. Run a
      # one-time smoke parse here so a misconfigured target_ruby
      # surfaces as a single project-level diagnostic instead of
      # crashing the whole run on the first file.
      def validate_target_ruby
        Prism.parse("nil", version: @configuration.target_ruby)
        nil
      rescue ArgumentError => e
        Diagnostic.new(
          path: ".rigor.yml", line: 1, column: 1,
          message: "target_ruby #{@configuration.target_ruby.inspect} is not accepted by Prism: #{e.message}",
          severity: :error,
          rule: "configuration-error",
          source_family: :builtin
        )
      end

      private

      # Editor mode § "Scope choice — option A". Under
      # `buffer:` non-nil the per-file analysis emits diagnostics
      # ONLY for the buffer's logical path; the rest of `paths:`
      # is consumed by the project-wide pre-passes (synthetic
      # methods, project-patched methods, plugin facts) but
      # contributes no per-file diagnostics. This is the v1 cut
      # before a per-file diagnostic cache exists; option B (full
      # project + incremental cache) is queued.
      #
      # The buffer's logical path is added to the file list even
      # if it's not under `paths:` — per design § "Failure
      # envelope": "--instead-of=Y with Y not under any paths:
      # directory → treated as a valid logical identity for the
      # buffer".
      def target_files(expansion)
        files = expansion.fetch(:files)
        # ADR-46 slice 2 — restrict the analyzed set to the affected
        # closure while the pre-pass (run separately over `expansion`'s
        # full file list) keeps the cross-file index complete. Buffer mode
        # takes precedence — its single logical path is the analyzed set.
        files = files.select { |path| @analyze_only.include?(path) } if @analyze_only
        return files if @buffer.nil?

        [@buffer.logical_path]
      end

      # Editor mode (`buffer:` non-nil) auto-flips the cache store
      # to `read_only: true` so multiple debounced editor invocations
      # against the same project don't churn the on-disk cache or
      # race on schema-version writes. Cache reads continue
      # unchanged; misses still run the producer block but the
      # result is not persisted. Per design doc § "Cache behaviour".
      def enforce_read_only_cache(cache_store, buffer)
        return cache_store if buffer.nil?
        return cache_store if cache_store.nil?
        return cache_store if cache_store.read_only?

        Cache::Store.new(root: cache_store.root, read_only: true)
      end

      # ADR-15 Phase 4b — pool mode is enabled when `@workers > 0`.
      # Editor mode (`buffer:` non-nil) silently overrides pool
      # mode to sequential: per design § "Ractor pool mode", the
      # pool's warm-up cost dominates one-file wall time, so the
      # pool gains nothing on a per-buffer invocation. The override
      # is part of the contract — not a degradation diagnostic —
      # because `--workers=N` is a project-scale knob and editor
      # mode is per-buffer; the conflict resolves toward the more
      # specific axis.
      def pool_mode?
        return false unless @workers.is_a?(Integer) && @workers.positive?

        @buffer.nil?
      end

      # ADR-15 Amendment (2026-05-20) — worker-pool backend selector.
      # `fork` is the active backend: separate processes sidestep both
      # the Ruby Bug #22075 use-after-free and the worker-side
      # `Ractor::IsolationError` that make the Ractor pool unusable
      # (see the ADR-15 Amendment +
      # docs/notes/20260520-ractor-pool-cruby-uaf.md). The Ractor pool
      # is preserved but off the default path — `RIGOR_POOL_BACKEND=ractor`
      # opts back in so it stays testable. Platforms without `fork`
      # (Windows) fall back to sequential.
      def pool_backend
        return :ractor if ENV["RIGOR_POOL_BACKEND"] == "ractor"
        return :fork if Process.respond_to?(:fork)

        :sequential
      end

      # Routes pool-mode analysis to the selected backend.
      def dispatch_pool(files)
        case pool_backend
        when :ractor then analyze_files_in_pool(files)
        when :fork   then analyze_files_in_fork_pool(files)
        else
          analyze_files_sequentially_fallback(
            files, reason: "fork-based parallelism is unavailable on this platform"
          )
        end
      end

      # Coordinator-side Environment used by the sequential code
      # path. Pool mode builds one Environment per worker inside
      # the worker Ractor's body instead.
      #
      # ADR-32 WD4 — `source_files:` is threaded down so that
      # `Environment.for_project` can invoke each loaded plugin's
      # `source_rbs_synthesizer` callable per project source file
      # at env-build time. Defaults to `[]` for callers that don't
      # have a file list yet (e.g. pre-pass-only build paths); in
      # that case no synthesised RBS is contributed.
      def build_runner_environment(source_files: [])
        Environment.for_project(
          libraries: @configuration.libraries,
          signature_paths: @configuration.signature_paths,
          cache_store: @cache_store,
          plugin_registry: @plugin_registry,
          dependency_source_index: @dependency_source_index,
          rbs_extended_reporter: @rbs_extended_reporter,
          boundary_cross_reporter: @boundary_cross_reporter,
          source_rbs_synthesis_reporter: @source_rbs_synthesis_reporter,
          bundler_bundle_path: @configuration.bundler_bundle_path,
          bundler_auto_detect: @configuration.bundler_auto_detect,
          bundler_lockfile: @configuration.bundler_lockfile,
          rbs_collection_lockfile: @configuration.rbs_collection_lockfile,
          rbs_collection_auto_detect: @configuration.rbs_collection_auto_detect,
          synthetic_method_index: @synthetic_method_index,
          project_patched_methods: @project_patched_methods,
          source_files: source_files
        )
      end

      # ADR-15 Phase 4b — Ractor pool around {WorkerSession}.
      # Spawns `@workers` Ractors; each takes the shareable
      # payload (Configuration, cache_root String, plugin
      # Blueprint Array, explain Boolean) and builds its OWN
      # WorkerSession internally. Files are distributed
      # round-robin across the pool; each worker writes back to
      # the main Ractor's mailbox via `Ractor.main.send` with
      # one of three message kinds:
      #
      # - `[:prepare, diagnostics]` — once at startup, the
      #   session's `prepare_diagnostics` snapshot. The
      #   coordinator keeps the FIRST worker's snapshot only
      #   (plugin `#prepare` is deterministic per plugin, so
      #   each worker produces the same diagnostic set; surfacing
      #   them once avoids N× duplication).
      # - `[:file, path, diagnostics]` — one per analysed file.
      # - `[:done, drained_reporters]` — once at exit, the
      #   per-worker reporter snapshots for end-of-pool merge.
      #
      # The Ruby 4.0+ Ractor model uses a single per-Ractor
      # mailbox (no `Ractor.yield`); workers push back via
      # `Ractor.main.send`. The coordinator drains its mailbox
      # via `Ractor.receive` until it has counted exactly
      # `pool.size` `:done` messages.
      #
      # Diagnostic order: original path order. Workers may
      # complete files out of order; the coordinator re-orders
      # via the `results_by_path` Hash before flattening.
      #
      # Reporter merge: per-worker `RbsExtended::Reporter` and
      # `BoundaryCrossReporter` entries are replayed into the
      # runner-side accumulators via their `record_*` APIs,
      # which dedupe on the same keys as a single-session run
      # would. Net result: reporter state is identical to the
      # sequential path.
      def analyze_files_in_pool(files) # rubocop:disable Metrics/MethodLength,Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
        # Pre-warm class-level lazy memos on the MAIN Ractor.
        # `Environment::ClassRegistry.default` is the
        # default kwarg threaded through `Environment.new`
        # inside each worker session; lazy-initialising it
        # from a non-main Ractor would trip
        # `Ractor::IsolationError`. Touching it here forces
        # the (shareable) registry into the class-ivar cache
        # before any worker reads.
        Environment::ClassRegistry.default

        # ADR-15 Phase 4b.x — pre-warm the RBS cache so
        # workers serve every reflection query from the
        # Marshal blob on disk. Without this, the first
        # cache MISS inside a worker falls through to
        # `RBS::EnvironmentLoader.new`, which reads a chain
        # of non-`Ractor.shareable?` RubyGems / RBS module
        # constants and raises `Ractor::IsolationError`.
        # Pre-warming requires a `cache_store`; the run aborts
        # to sequential mode otherwise. See ADR-15 Phase 4b.x
        # for the full chain of failing constants.
        if @cache_store.nil?
          return analyze_files_sequentially_fallback(
            files, reason: "pool mode requires a cache_store (--no-cache disables pool)"
          )
        end
        prewarm_rbs_cache_for_pool

        configuration = @configuration
        cache_root = @cache_store&.root
        blueprints = @plugin_registry.blueprints
        explain = @explain
        # ADR-32 WD4 — the full project file list travels into
        # every Ractor worker so each worker's WorkerSession
        # can invoke loaded plugins' source_rbs_synthesizers at
        # env-build time. The list is a frozen Array<String>;
        # cheaply shareable.
        shareable_source_files = files.map { |path| path.to_s.dup.freeze }.freeze

        pool = Array.new(@workers) do
          Ractor.new(configuration, cache_root, blueprints, explain, shareable_source_files) do |configuration, cache_root, blueprints, explain, shareable_source_files| # rubocop:disable Layout/LineLength
            cache_store = cache_root ? Rigor::Cache::Store.new(root: cache_root) : nil
            session = Rigor::Analysis::WorkerSession.new(
              configuration: configuration,
              cache_store: cache_store,
              plugin_blueprints: blueprints,
              explain: explain,
              source_files: shareable_source_files
            )
            main = Ractor.main
            main.send([:prepare, session.prepare_diagnostics])

            loop do
              msg = Ractor.receive
              break if msg.nil?

              main.send([:file, msg, session.analyze(msg)])
            end

            main.send([:done, session.drain_reporters])
          end
        end

        files.each_with_index { |path, index| pool[index % pool.size].send(path) }
        pool.each { |worker| worker.send(nil) }

        prepare_diagnostics = nil
        results_by_path = {}
        done_count = 0

        while done_count < pool.size
          message = Ractor.receive
          case message.first
          when :prepare
            prepare_diagnostics ||= message.last
          when :file
            results_by_path[message[1]] = message[2]
          when :done
            merge_worker_reporters(message.last)
            done_count += 1
          end
        end

        pool.each(&:join)

        Array(prepare_diagnostics) + files.flat_map { |path| results_by_path.fetch(path, []) }
      end

      # ADR-15 Amendment (2026-05-20) — fork-based worker pool, the
      # active backend for `workers > 0`. Builds ONE {WorkerSession}
      # on the parent, then `fork`s N children that copy-on-write
      # inherit it. Each child analyses a contiguous slice of `files`
      # and writes a Marshal'd `{results:, reporters:}` payload to a
      # temp file; the parent `Process.wait`s every child, merges the
      # payloads, and re-orders diagnostics by original path order.
      #
      # Separate processes have separate GC heaps and `vm->ci_table`
      # (immune to Ruby Bug #22075) and copy-on-write-inherit every
      # constant (no `Ractor.shareable?` constraint). See the ADR-15
      # Amendment + docs/notes/20260520-ractor-pool-cruby-uaf.md.
      #
      # A child that exits non-zero (crash / unmarshalable payload) is
      # degraded: the parent re-analyses that slice in-process and
      # prepends a `pool-degraded` warning.
      def analyze_files_in_fork_pool(files) # rubocop:disable Metrics/AbcSize
        Environment::ClassRegistry.default

        session = WorkerSession.new(
          configuration: @configuration,
          cache_store: @cache_store,
          plugin_blueprints: @plugin_registry.blueprints,
          explain: @explain,
          synthetic_method_index: @synthetic_method_index,
          project_patched_methods: @project_patched_methods,
          source_files: files
        )
        # Force the full RBS load on the parent so children
        # copy-on-write inherit a warm Environment rather than each
        # rebuilding it after the fork.
        session.environment.rbs_loader&.prewarm
        snapshot_fork_pool_stats(session) if @collect_stats

        worker_count = [@workers, files.size].min
        slices = files.each_slice((files.size.to_f / worker_count).ceil).to_a
        results_by_path = {}

        degraded = Dir.mktmpdir("rigor-fork-pool") do |tmpdir|
          children = slices.each_with_index.map do |slice, index|
            out_path = File.join(tmpdir, "worker-#{index}")
            { pid: fork { run_fork_worker(session, slice, out_path) },
              slice: slice, out_path: out_path }
          end
          collect_fork_results(children, results_by_path)
        end

        unless degraded.empty?
          degraded.each { |path| results_by_path[path] = session.analyze(path) }
          merge_worker_reporters(session.drain_reporters)
        end

        diagnostics = Array(session.prepare_diagnostics) +
                      files.flat_map { |path| results_by_path.fetch(path, []) }
        degraded.empty? ? diagnostics : diagnostics.unshift(fork_degraded_diagnostic(degraded.size))
      end

      # Child-process body for {#analyze_files_in_fork_pool}. Analyses
      # the slice with the copy-on-write-inherited session and writes
      # the Marshal'd payload to `out_path`. `exit!` skips `at_exit` /
      # stdio flush — the payload is already durable on disk by then.
      def run_fork_worker(session, slice, out_path)
        results = slice.to_h { |path| [path, session.analyze(path)] }
        payload = { results: results, reporters: session.drain_reporters }
        File.binwrite(out_path, Marshal.dump(payload))
        exit!(0)
      rescue StandardError
        exit!(1)
      end

      # Snapshots `class_decl_paths` from the parent session's loader
      # so end-of-run {RunStats} can attribute the RBS class universe.
      def snapshot_fork_pool_stats(session)
        loader = session.environment.rbs_loader
        @class_decl_paths_snapshot = loader&.class_decl_paths || {}.freeze
        @signature_paths_snapshot = loader&.signature_paths || [].freeze
      end

      # Waits for every forked child, merges each successful payload
      # into `results_by_path`, and returns the file paths whose
      # worker exited abnormally (for in-process degrade).
      def collect_fork_results(children, results_by_path)
        degraded = []
        children.each do |child|
          _, status = Process.waitpid2(child[:pid])
          payload = fork_worker_payload(status, child[:out_path])
          if payload
            results_by_path.merge!(payload.fetch(:results))
            merge_worker_reporters(payload.fetch(:reporters))
          else
            degraded.concat(child[:slice])
          end
        end
        degraded
      end

      # @return [Hash, nil] the child's `{results:, reporters:}`
      #   payload, or nil when the child exited abnormally or wrote no
      #   readable payload. `Marshal.load` is safe here: the blob was
      #   written by our own forked child to a temp file we created.
      def fork_worker_payload(status, out_path)
        return nil unless status.success? && File.exist?(out_path)

        Marshal.load(File.binread(out_path)) # rubocop:disable Security/MarshalLoad
      rescue StandardError
        nil
      end

      def fork_degraded_diagnostic(count)
        Diagnostic.new(
          path: ".rigor.yml", line: 1, column: 1,
          message: "fork pool degraded: #{count} file(s) re-analysed in-process " \
                   "after a worker exited abnormally",
          severity: :warning, rule: "pool-degraded", source_family: :builtin
        )
      end

      # End-of-run telemetry. Walks the cached
      # `class_decl_paths` snapshot (sequential mode: from
      # the coordinator's environment; pool mode: from the
      # first worker's `:prepare` payload) and partitions the
      # RBS class universe into "project sig/" (paths under
      # `signature_paths`) vs "bundled" (everything else).
      # Gem source-walk counts come from `dependency_source_index`
      # which is already constructed regardless of pool mode.
      # Wall + RSS are single syscalls; total cost is bounded
      # by the snapshot size (~1000-2000 entries).
      def build_run_stats(wall_started_at:, expansion:)
        snapshot = @class_decl_paths_snapshot
        project_sig, bundled = RunStats.partition_classes(
          class_decl_paths: snapshot,
          signature_paths: @signature_paths_snapshot
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

      # ADR-15 Phase 4b.x — drives every cached RBS producer
      # on the main Ractor so each worker can serve all
      # reflection queries from disk (Marshal-load only).
      # Builds a single coordinator-side {Environment} for
      # this purpose; the env object is discarded immediately
      # after the cache is warm — workers build their own
      # `Environment.for_project` inside the Ractor body,
      # which then routes through `cached_env` instead of
      # `RBS::EnvironmentLoader.new`.
      def prewarm_rbs_cache_for_pool
        warm_env = Environment.for_project(
          libraries: @configuration.libraries,
          signature_paths: @configuration.signature_paths,
          cache_store: @cache_store,
          bundler_bundle_path: @configuration.bundler_bundle_path,
          bundler_auto_detect: @configuration.bundler_auto_detect,
          bundler_lockfile: @configuration.bundler_lockfile,
          rbs_collection_lockfile: @configuration.rbs_collection_lockfile,
          rbs_collection_auto_detect: @configuration.rbs_collection_auto_detect
        )
        warm_env.rbs_loader&.prewarm
      end

      # ADR-15 Phase 4b.x — pool-mode safety net. When pool
      # mode is configured but a precondition fails (currently:
      # `--no-cache` would force workers through
      # `EnvironmentLoader.new`), degrade to sequential
      # analysis with a `:warning` `pool-degraded` diagnostic
      # at run start. The actual per-file analysis runs on
      # the coordinator, identical to the default sequential
      # path.
      def analyze_files_sequentially_fallback(files, reason:)
        environment = build_runner_environment
        diagnostics = files.flat_map { |path| analyze_file(path, environment) }
        loader = environment.rbs_loader
        @class_decl_paths_snapshot = loader&.class_decl_paths || {}.freeze
        @signature_paths_snapshot = loader&.signature_paths || [].freeze
        diagnostics.unshift(
          Diagnostic.new(
            path: ".rigor.yml", line: 1, column: 1,
            message: "pool mode degraded to sequential: #{reason}",
            severity: :warning, rule: "pool-degraded", source_family: :builtin
          )
        )
      end

      def merge_worker_reporters(drained)
        rbs = drained.fetch(:rbs_extended)
        rbs.fetch(:unresolved_payloads).each do |entry|
          @rbs_extended_reporter.record_unresolved(
            payload: entry.payload, source_location: entry.source_location
          )
        end
        rbs.fetch(:lossy_projections).each do |entry|
          @rbs_extended_reporter.record_lossy_projection(
            head: entry.head, source_location: entry.source_location
          )
        end
        drained.fetch(:boundary_cross).each do |entry|
          @boundary_cross_reporter.record(
            class_name: entry.class_name,
            method_name: entry.method_name,
            gem_name: entry.gem_name,
            rbs_display: entry.rbs_display
          )
        end
        # ADR-32 WD6 — merge per-worker synthesizer failures
        # back into the coordinator's reporter. Fetched with a
        # default empty array so older drains (pre-slice-2)
        # remain compatible.
        Array(drained[:source_rbs_synthesis]).each do |entry|
          @source_rbs_synthesis_reporter.record(
            plugin_id: entry.plugin_id, path: entry.path, message: entry.message
          )
        end
      end

      # Loads project-configured plugins through {Rigor::Plugin::Loader}
      # and returns the resulting {Rigor::Plugin::Registry}. Loader
      # failures are isolated: each surfaces as a `:plugin_loader`
      # diagnostic on the run's `Result` rather than aborting the
      # analysis. Plugins that load successfully but contribute no
      # protocol hooks are inert in slice 1; later v0.1.0 slices
      # wire the contribution merger through this registry.
      def load_plugins
        return Plugin::Registry::EMPTY if @configuration.plugins.empty?

        services = Plugin::Services.new(
          reflection: Reflection,
          type: Type::Combinator,
          configuration: @configuration,
          cache_store: @cache_store,
          trust_policy: build_trust_policy
        )
        if @plugin_requirer
          Plugin::Loader.load(configuration: @configuration, services: services, requirer: @plugin_requirer)
        else
          Plugin::Loader.load(configuration: @configuration, services: services)
        end
      end

      # Builds the {Rigor::Plugin::TrustPolicy} for this run. Trusted
      # gems are the gem-name half of every entry in
      # `Configuration#plugins`. Allowed read roots default to the
      # project root (CWD), the project's signature_paths, and each
      # trusted gem's `Gem::Specification#full_gem_path`, plus any
      # extras the user listed under `plugins_io.allowed_paths`.
      # Slice 2 keeps `network_policy` `:disabled` — the only value
      # the configuration accepts today.
      def build_trust_policy
        trusted_gems = @configuration.plugins.map { |entry| trusted_gem_name(entry) }.uniq
        roots = [Dir.pwd]
        Array(@configuration.signature_paths).each { |sp| roots << File.expand_path(sp) }
        trusted_gems.each do |gem_name|
          path = trusted_gem_root(gem_name)
          roots << path if path
        end
        @configuration.plugins_io_allowed_paths.each { |p| roots << File.expand_path(p) }

        Plugin::TrustPolicy.new(
          trusted_gems: trusted_gems,
          allowed_read_roots: roots,
          network_policy: @configuration.plugins_io_network,
          allowed_url_hosts: @configuration.plugins_io_allowed_url_hosts
        )
      end

      def trusted_gem_name(entry)
        case entry
        when String then entry
        when Hash then entry["gem"] || entry["id"]
        end
      end

      def trusted_gem_root(gem_name)
        return nil if gem_name.nil? || gem_name.empty?

        spec = Gem.loaded_specs[gem_name]
        spec&.full_gem_path # rigor:disable undefined-method
      rescue StandardError
        nil
      end

      # ADR-8 § "Severity profile" — re-stamps each diagnostic's
      # severity from the configured profile + per-rule
      # overrides. Rules emit with their authored severity; the
      # profile is the final filter. Diagnostics whose resolved
      # severity is `:off` are dropped from the run result.
      def apply_severity_profile(diagnostics)
        diagnostics.filter_map { |diagnostic| stamp_severity(diagnostic) }
      end

      def stamp_severity(diagnostic)
        return diagnostic if diagnostic.rule.nil?

        resolved = Configuration::SeverityProfile.resolve(
          rule: diagnostic.rule,
          authored_severity: diagnostic.severity,
          profile: @configuration.severity_profile,
          overrides: @configuration.severity_overrides
        )
        return nil if resolved == :off
        return diagnostic if resolved == diagnostic.severity

        Diagnostic.new(
          path: diagnostic.path,
          line: diagnostic.line,
          column: diagnostic.column,
          message: diagnostic.message,
          severity: resolved,
          rule: diagnostic.rule,
          source_family: diagnostic.source_family
        )
      end

      def plugin_load_diagnostics
        @plugin_registry.load_errors.map do |error|
          Diagnostic.new(
            path: ".rigor.yml",
            line: 1,
            column: 1,
            message: error.message,
            severity: :error,
            rule: "load-error",
            source_family: :plugin_loader
          )
        end
      end

      # ADR-10 § "Diagnostic prefix family" — surfaces gems
      # listed in `dependencies.source_inference` that RubyGems
      # could not resolve. The run continues; the gem simply
      # contributes nothing this session, mirroring the
      # plugin-load error envelope. Authored `:warning` because
      # an unresolvable gem usually means a typo or a missing
      # `bundle install` rather than a project-blocking problem;
      # the severity profile still re-stamps it.
      def dependency_source_diagnostics
        @dependency_source_index.unresolvable.map do |entry|
          Diagnostic.new(
            path: ".rigor.yml",
            line: 1,
            column: 1,
            message: "dependencies.source_inference[].gem #{entry.gem_name.inspect} could not be " \
                     "resolved (#{entry.reason}); skipping",
            severity: :warning,
            rule: "dynamic.dependency-source.gem-not-found",
            source_family: :builtin
          )
        end
      end

      # ADR-10 § "Budget interaction" / slice 4 — emits one
      # `:warning` per gem whose Walker run hit the
      # `dependencies.budget_per_gem` cap. The cap is a Walker-
      # side guard rail (slice 4 picks the (α) semantics from
      # ADR-10 WD4: harvesting stops, the dispatcher behaves
      # exactly as before for unrecorded methods). The
      # diagnostic names the gem and points the user at the
      # three remediations: ship RBS, reduce `mode:` from
      # `full` to `when_missing`, or de-list the gem.
      # ADR-10 § "config-conflict diagnostic" / 5d — surfaces
      # `Configuration::Dependencies` warnings accumulated
      # during `from_h` deduplication of the `includes:`-chain
      # source_inference array. Each warning describes a
      # per-gem mode conflict that the merge resolved
      # right-wins; the user sees one diagnostic per conflict.
      # `:warning` matches the user's "warn but don't block"
      # preference per the design discussion.
      def dependency_source_config_conflict_diagnostics
        @configuration.dependencies.warnings.map do |message|
          Diagnostic.new(
            path: ".rigor.yml",
            line: 1,
            column: 1,
            message: message,
            severity: :warning,
            rule: "dynamic.dependency-source.config-conflict",
            source_family: :builtin
          )
        end
      end

      def dependency_source_budget_diagnostics
        budget = @configuration.dependencies.budget_per_gem
        @dependency_source_index.budget_exceeded.map do |gem_name|
          Diagnostic.new(
            path: ".rigor.yml",
            line: 1,
            column: 1,
            message: "dependencies.source_inference[].gem #{gem_name.inspect} exceeded the per-gem " \
                     "catalog cap (#{budget} method definitions); the remaining methods fall back " \
                     "to the existing RBS-or-Dynamic[top] boundary. Ship RBS for the gem, set " \
                     "`mode: when_missing` instead of `full`, or de-list the gem.",
            severity: :warning,
            rule: "dynamic.dependency-source.budget-exceeded",
            source_family: :builtin
          )
        end
      end

      # O4 Layer 3 slice 3 — graceful-degradation coverage
      # report. When the project has a `Gemfile.lock` (slice 1)
      # and one or more locked gems are not covered by ANY of
      # the four RBS resolution paths (`DEFAULT_LIBRARIES`,
      # `data/vendored_gem_sigs/`, slice-1 bundle-shipped
      # `sig/`, slice-2 `rbs_collection.lock.yaml`), emit a
      # single `:info` diagnostic summarising the uncovered set
      # so the user can act on it (run `rbs collection install`,
      # opt the gem into `dependencies.source_inference:`, or
      # accept the `Dynamic[T]` fallback).
      #
      # Suppressed when the lockfile is empty, when every gem
      # is covered, or when slice 1's `bundler.lockfile`
      # discovery returned nothing (no lockfile to read).
      def rbs_coverage_diagnostics
        locked = Environment::LockfileResolver.locked_gems(
          lockfile_path: @configuration.bundler_lockfile,
          project_root: Dir.pwd,
          auto_detect: @configuration.bundler_auto_detect
        )
        return [] if locked.empty?

        bundle_sig_paths = Environment::BundleSigDiscovery.discover(
          bundle_path: @configuration.bundler_bundle_path,
          project_root: Dir.pwd,
          auto_detect: @configuration.bundler_auto_detect,
          locked_gems: locked
        )
        collection_paths = Environment::RbsCollectionDiscovery.discover(
          lockfile_path: @configuration.rbs_collection_lockfile,
          project_root: Dir.pwd,
          auto_detect: @configuration.rbs_collection_auto_detect
        )
        rows = Environment::RbsCoverageReport.classify(
          locked_gems: locked,
          default_libraries: Environment::DEFAULT_LIBRARIES,
          bundle_sig_paths: bundle_sig_paths,
          rbs_collection_paths: collection_paths
        )
        missing = Environment::RbsCoverageReport.missing(rows)
        return [] if missing.empty?

        [build_rbs_coverage_missing_diagnostic(missing)]
      end

      # Robustness uplift companion (ADR-5) — when the project's
      # `signature_paths:` RBS declared qualified names without their
      # enclosing namespace, `RbsLoader` synthesizes the missing
      # `module`s so the otherwise-inert signatures resolve. Surface a
      # single `:info` diagnostic naming them so the user knows their
      # sig set is malformed (`rbs validate` rejects it) and can fix it
      # at the source. Authored `:info`: the analysis already succeeded;
      # this is advisory, never a gate. Empty for a well-formed sig set.
      def rbs_synthesized_namespace_diagnostics
        synthesized = @synthesized_namespaces_snapshot
        return [] if synthesized.nil? || synthesized.empty?

        [build_rbs_synthesized_namespace_diagnostic(synthesized)]
      end

      # Maps the per-run `rigor:v1:conforms-to` scan results into
      # diagnostics (spec: `rbs-extended.md` § "Explicit conformance
      # directive"). A class that declares `conforms-to _Interface`
      # but is missing a required interface method surfaces as
      # `rbs_extended.unsatisfied-conformance`; an unresolvable
      # interface name surfaces as `dynamic.rbs-extended.unresolved`
      # `:info` (the same fail-soft channel the other directive
      # parsers use). Empty for a project with no directive, a
      # well-formed conformance, or a non-sequential pool run (the
      # snapshot mirrors `synthesized_namespaces`).
      def conforms_to_diagnostics
        results = @conformance_results_snapshot
        return [] if results.nil? || results.empty?

        results.map { |record| build_conformance_diagnostic(record) }
      end

      def build_conformance_diagnostic(record)
        case record
        when RbsExtended::ConformanceChecker::Unsatisfied
          build_unsatisfied_conformance_diagnostic(record)
        when RbsExtended::ConformanceChecker::IncompatibleSignature
          build_incompatible_signature_diagnostic(record)
        else # UnresolvedInterface
          build_reporter_diagnostic(
            record.location,
            rule: "dynamic.rbs-extended.unresolved",
            message: "`#{record.class_name}` declares `conforms-to #{record.interface_name}` but " \
                     "interface `#{record.interface_name}` is not loaded. Check for a typo or add " \
                     "the `sig`/library that declares it to the RBS load path."
          )
        end
      end

      def build_unsatisfied_conformance_diagnostic(record)
        path, line, column = location_fields(record.location)
        Diagnostic.new(
          path: path, line: line, column: column,
          message: "`#{record.class_name}` declares `conforms-to #{record.interface_name}` " \
                   "but does not provide #{pluralize_methods(record.missing_methods)}: " \
                   "#{record.missing_methods.map { |m| "`##{m}`" }.join(', ')}. Implement the " \
                   "missing method(s) or remove the directive.",
          severity: :warning,
          rule: "rbs_extended.unsatisfied-conformance",
          source_family: :builtin
        )
      end

      def build_incompatible_signature_diagnostic(record)
        path, line, column = location_fields(record.location)
        Diagnostic.new(
          path: path, line: line, column: column,
          message: "`#{record.class_name}##{record.method_name}` does not satisfy " \
                   "`conforms-to #{record.interface_name}`: #{record.detail}. Adjust the " \
                   "signature to a subtype of the interface contract.",
          severity: :warning,
          rule: "rbs_extended.unsatisfied-conformance",
          source_family: :builtin,
          method_name: record.method_name
        )
      end

      def pluralize_methods(methods)
        methods.size == 1 ? "required method" : "#{methods.size} required methods"
      end

      # True when the project declares its own `signature_paths:` (the
      # only place the qualified-name-without-namespace mistake lives).
      def project_signature_paths?
        paths = @configuration.signature_paths
        !(paths.nil? || paths.empty?)
      end

      def build_rbs_synthesized_namespace_diagnostic(synthesized)
        sample_size = 5
        sample = synthesized.first(sample_size)
        suffix = synthesized.size > sample_size ? ", and #{synthesized.size - sample_size} more" : ""
        Diagnostic.new(
          path: ".rigor.yml",
          line: 1,
          column: 1,
          message: "#{synthesized.size} RBS namespace(s) under `signature_paths:` are " \
                   "referenced by qualified declarations (e.g. `class Foo::Bar`) but never " \
                   "declared: #{sample.join(', ')}#{suffix}. `rbs validate` rejects this; " \
                   "Rigor synthesized the missing `module`(s) so the signatures still " \
                   "resolve. Declare each (`module <name>` / `class <name>`) in your RBS to " \
                   "make the sig set valid upstream.",
          severity: :info,
          rule: "rbs.coverage.synthesized-namespace",
          source_family: :builtin
        )
      end

      def build_rbs_coverage_missing_diagnostic(missing)
        sample_size = 5
        sample = missing.first(sample_size).map(&:gem_name)
        suffix = missing.size > sample_size ? ", and #{missing.size - sample_size} more" : ""
        Diagnostic.new(
          path: ".rigor.yml",
          line: 1,
          column: 1,
          message: "#{missing.size} gem(s) in Gemfile.lock have no RBS available: " \
                   "#{sample.join(', ')}#{suffix}. " \
                   "Consider `rbs collection install` to fetch community RBS from " \
                   "`ruby/gem_rbs_collection`, ship `sig/` in the gem itself, or " \
                   "opt the gem into `dependencies.source_inference:` in `.rigor.yml`.",
          severity: :info,
          rule: "rbs.coverage.missing-gem",
          source_family: :builtin
        )
      end

      # ADR-13 slice 3b — drains the per-run
      # {RbsExtended::Reporter} into one diagnostic per accumulated
      # event:
      #
      # - `dynamic.rbs-extended.unresolved` for every annotation
      #   payload the parser could not turn into a {Rigor::Type}.
      #   Surfaces typos and references to plugin-supplied names
      #   the project did not enable.
      # - `dynamic.shape.lossy-projection` for every shape-projection
      #   type function (`pick_of`, …) applied to a carrier that
      #   loses precision (anything other than `HashShape` / `Tuple`).
      #
      # Both are authored `:info`; the severity profile re-stamps
      # them per project taste. Path / line / column come from the
      # annotation's `RBS::Location` when available, falling back
      # to `.rigor.yml`-style file-level attribution otherwise.
      def rbs_extended_reporter_diagnostics
        return [] if @rbs_extended_reporter.empty?

        unresolved = @rbs_extended_reporter.unresolved_payloads.map do |entry|
          build_reporter_diagnostic(
            entry.source_location,
            rule: "dynamic.rbs-extended.unresolved",
            message: "`RBS::Extended` directive payload could not be resolved: " \
                     "#{entry.payload.inspect}. Check for typos or enable a plugin " \
                     "that contributes the referenced type vocabulary."
          )
        end

        lossy = @rbs_extended_reporter.lossy_projections.map do |entry|
          build_reporter_diagnostic(
            entry.source_location,
            rule: "dynamic.shape.lossy-projection",
            message: "Shape projection `#{entry.head}` applied to a carrier without a " \
                     "literal shape; the projection degrades to the input type. Author " \
                     "a `HashShape` / `Tuple` carrier or accept the unchanged result."
          )
        end

        unresolved + lossy
      end

      # ADR-10 slice 5c — drains the per-run
      # {DependencySourceInference::BoundaryCrossReporter} into
      # `dynamic.dependency-source.boundary-cross` `:info`
      # diagnostics. Each event flags a call site where RBS
      # dispatch produced a concrete answer AND a `mode: :full`
      # opt-in gem's source catalog ALSO contains an entry for
      # the same `(class_name, method_name)` — i.e., both
      # contracts have an opinion. RBS still wins on the
      # dispatch result; the diagnostic is purely advisory so
      # the user can verify the two contracts haven't drifted.
      #
      # Severity profile re-stamps the rule per project taste.
      # The diagnostic carries no `path` / `line` / `column`
      # because the crossing is per-method-per-gem, not
      # per-call-site — the diagnostic anchors at `.rigor.yml`
      # like the other `dependency-source.*` diagnostics that
      # report on opt-in configuration.
      # ADR-32 WD6 — drains the per-run
      # {Plugin::SourceRbsSynthesisReporter} into
      # `source-rbs-synthesis-failed` `:info` diagnostics. Each
      # entry names the plugin that owns the synthesizer, the
      # source file the rbs-inline parser couldn't process, and
      # the upstream error message. The synthesizer-emitting
      # plugin (currently only `rigor-rbs-inline`) treats a
      # parse failure as a no-contribution event so analysis
      # continues; this stream surfaces the failure so the user
      # can see which files contributed nothing and why.
      #
      # Severity profile re-stamps the rule per project taste.
      def source_rbs_synthesis_diagnostics
        return [] if @source_rbs_synthesis_reporter.empty?

        @source_rbs_synthesis_reporter.entries.map do |entry|
          Diagnostic.new(
            path: entry.path, line: 1, column: 1,
            message: "plugin `#{entry.plugin_id}` failed to synthesise RBS from this file: " \
                     "#{entry.message}. The file's analysis falls back to no inline-RBS " \
                     "contribution. Fix the inline-RBS comment grammar or remove the " \
                     "annotation to silence this diagnostic.",
            severity: :info,
            rule: "source-rbs-synthesis-failed",
            source_family: :builtin
          )
        end
      end

      def boundary_cross_diagnostics
        return [] if @boundary_cross_reporter.empty?

        @boundary_cross_reporter.entries.map do |entry|
          Diagnostic.new(
            path: ".rigor.yml", line: 1, column: 1,
            message: "`#{entry.class_name}##{entry.method_name}` is contributed by both " \
                     "RBS (#{entry.rbs_display}) and the `mode: :full` opt-in gem " \
                     "`#{entry.gem_name}`. RBS wins on dispatch; verify the gem source " \
                     "has not drifted from its RBS contract.",
            severity: :info,
            rule: "dynamic.dependency-source.boundary-cross",
            source_family: :builtin
          )
        end
      end

      def build_reporter_diagnostic(source_location, rule:, message:)
        path, line, column = location_fields(source_location)
        Diagnostic.new(
          path: path, line: line, column: column,
          message: message, severity: :info, rule: rule, source_family: :builtin
        )
      end

      def location_fields(source_location)
        return [".rigor.yml", 1, 1] if source_location.nil?

        path = location_path(source_location)
        line = source_location.respond_to?(:start_line) ? source_location.start_line : 1
        column = source_location.respond_to?(:start_column) ? source_location.start_column + 1 : 1
        [path, line, column]
      rescue StandardError
        [".rigor.yml", 1, 1]
      end

      def location_path(source_location)
        buffer = source_location.respond_to?(:buffer) ? source_location.buffer : nil
        return ".rigor.yml" if buffer.nil? || !buffer.respond_to?(:name)

        name = buffer.name.to_s
        name.empty? ? ".rigor.yml" : name
      end

      # ADR-9 slice 3 — invokes every loaded plugin's `#prepare`
      # hook once per run, after the loader's `#init` pass and
      # before per-file iteration. Plugins publish facts here
      # for cross-plugin consumption via the shared
      # `services.fact_store`. Failures isolate as
      # `:plugin_loader runtime-error` diagnostics, mirroring the
      # `#diagnostics_for_file` raise envelope in
      # `plugin_runtime_error_diagnostic`.
      #
      # Slice 3 visits plugins in registration order. Slice 5
      # introduces topological ordering by `manifest(consumes:)`
      # so producers always run before consumers; until then,
      # `Configuration#plugins` order MUST be producer-first if
      # cross-plugin dependencies exist.
      def plugin_prepare_diagnostics
        return [] if @plugin_registry.empty?

        @plugin_registry.plugins.flat_map { |plugin| invoke_plugin_prepare(plugin) }
      end

      def invoke_plugin_prepare(plugin)
        plugin.prepare(plugin.services)
        []
      rescue StandardError => e
        [plugin_prepare_error_diagnostic(plugin, e)]
      end

      def plugin_prepare_error_diagnostic(plugin, error)
        plugin_id = safe_plugin_id(plugin)
        Diagnostic.new(
          path: ".rigor.yml",
          line: 1,
          column: 1,
          message: "plugin #{plugin_id.inspect} raised during prepare: " \
                   "#{error.class}: #{error.message}",
          severity: :error,
          rule: "runtime-error",
          source_family: :plugin_loader
        )
      end

      # ADR-7 § "Slice 5-A/5-B" — invokes every loaded plugin's
      # per-file diagnostic emission hook
      # (`Plugin::Base#diagnostics_for_file`) and re-stamps the
      # returned diagnostics with
      # `source_family: "plugin.<manifest.id>"` so plugin
      # authors cannot accidentally publish under another
      # plugin's identifier or under `:builtin`. Plugin
      # exceptions are isolated per ADR-2 § "Plugin Trust and
      # I/O Policy" — a raise from one plugin becomes a
      # `:plugin_loader` `runtime-error` diagnostic without
      # affecting other plugins or the rest of the run.
      # ADR-52 WD1 — only the plugins that overrode
      # `#diagnostics_for_file` or declared a `node_rule` are visited
      # (`contribution_index.for_file_diagnostics`); a skipped plugin's
      # two hooks could only have returned `[]`.
      def plugin_emitted_diagnostics(path, root, scope)
        return [] if @plugin_registry.empty?

        @plugin_registry.contribution_index.for_file_diagnostics.flat_map do |plugin|
          collect_plugin_diagnostics(plugin, path, root, scope)
        end
      end

      def collect_plugin_diagnostics(plugin, path, root, scope)
        raw = Array(plugin.diagnostics_for_file(path: path, scope: scope, root: root))
        raw += plugin.node_rule_diagnostics(path: path, scope: scope, root: root)
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
      # - `:errors` — `Diagnostic` entries for each path that
      #   does not exist or is not a recognisable Ruby source.
      #
      # Surfacing path errors is a first-preview must-have:
      # `rigor check ./does_not_exist.rb` previously exited
      # cleanly with no output, which silently masked typos.
      def expand_paths(paths)
        files = []
        errors = []
        Array(paths).each do |path|
          if File.directory?(path)
            files.concat(reject_excluded(Dir.glob(File.join(path, RUBY_GLOB))))
          # Editor-mode bypass: the buffer's logical path is treated
          # as a real `.rb` file regardless of on-disk presence —
          # `parse_source` reads bytes from the buffer's physical
          # path. Common case: LSP client editing a brand-new file.
          elsif accept_as_ruby_file?(path)
            files << path
          elsif File.exist?(path)
            errors << path_error(path, "not a Ruby file (expected `.rb` or a directory)")
          else
            errors << path_error(path, "no such file or directory")
          end
        end
        { files: files, errors: errors }
      end

      def accept_as_ruby_file?(path)
        (File.file?(path) && path.end_with?(".rb")) ||
          (@buffer && path == @buffer.logical_path) ||
          @in_memory_sources&.key?(path)
      end

      # `Configuration#exclude_patterns` is a list of glob patterns
      # checked against each globbed path via `File.fnmatch?` (without
      # `FNM_PATHNAME`, so `**` and `*` both span path separators —
      # the patterns behave like substring globs). Built-in defaults
      # exclude `vendor/bundle`, `.bundle`, `node_modules`, and `tmp`
      # so the analyser never walks into vendored deps or build
      # artefacts. User-supplied entries (`.rigor.yml` `exclude:`)
      # layer on top. Explicit file arguments to the CLI bypass this
      # filter — only the directory-glob expansion is filtered.
      def reject_excluded(file_list)
        return file_list if @configuration.exclude_patterns.empty?

        file_list.reject { |path| excluded?(path) }
      end

      def excluded?(path)
        @configuration.exclude_patterns.any? { |pattern| File.fnmatch?(pattern, path) }
      end

      def path_error(path, message)
        Diagnostic.new(
          path: path,
          line: 1,
          column: 1,
          message: message,
          severity: :error
        )
      end

      # Reads + parses the source at `path`. Under editor mode
      # (`@buffer` set) reads bytes from `@buffer.physical_path`
      # when `path` matches the logical binding, then parses with
      # `filepath: path` so Prism's location data carries the
      # LOGICAL path. Non-binding paths go through the cheaper
      # `Prism.parse_file` codepath unchanged.
      def parse_source(path)
        if @in_memory_sources&.key?(path)
          return Prism.parse(@in_memory_sources[path], filepath: path, version: @configuration.target_ruby)
        end

        physical = @buffer ? @buffer.resolve(path) : path
        return Prism.parse_file(physical, version: @configuration.target_ruby) if physical == path

        Prism.parse(File.read(physical), filepath: path, version: @configuration.target_ruby)
      end

      # Seeds the cross-file project pre-pass indexes onto a
      # fresh per-file scope: discovered classes, and the ADR-24
      # def-node / superclass / included-module maps. Each is
      # applied only when non-empty so a runner constructed
      # without the project pre-pass (e.g. a single-file probe)
      # keeps an empty seed.
      def seed_project_scope(scope)
        scope = scope.with_discovered_classes(@project_discovered_classes) unless @project_discovered_classes.empty?
        unless @project_discovered_def_nodes.empty?
          scope = scope.with_discovered_def_nodes(@project_discovered_def_nodes)
        end
        unless @project_discovered_def_sources.empty?
          scope = scope.with_discovered_def_sources(@project_discovered_def_sources)
        end
        unless @project_discovered_superclasses.empty?
          scope = scope.with_discovered_superclasses(@project_discovered_superclasses)
        end
        scope = scope.with_discovered_includes(@project_discovered_includes) unless @project_discovered_includes.empty?
        unless @project_discovered_method_visibilities.empty?
          scope = scope.with_discovered_method_visibilities(@project_discovered_method_visibilities)
        end
        scope = scope.with_discovered_methods(@project_discovered_methods) unless @project_discovered_methods.empty?
        scope = scope.with_data_member_layouts(@project_data_member_layouts) unless @project_data_member_layouts.empty?
        # ADR-46 slice 1 — the class-declaration source map is read only by
        # the ancestry accessors during dependency recording, so seed it
        # only when recording is on; a normal run never carries it.
        if @record_dependencies && !@project_discovered_class_sources.empty?
          scope = scope.with_discovered_class_sources(@project_discovered_class_sources)
        end
        scope
      end

      # ADR-46 slice 1 — when dependency recording is enabled, wrap the
      # per-file analysis so the cross-file reads its inference makes are
      # captured into `file_dependencies[path]`. Off by default: a normal
      # run calls the body directly and the instrumented `Scope` accessors
      # short-circuit on `DependencyRecorder.active? == false`. Recording
      # is observational, so diagnostics are byte-identical either way.
      def analyze_file(path, environment)
        return analyze_file_body(path, environment) unless @record_dependencies

        diagnostics = nil
        record = DependencyRecorder.record_for(path) do
          diagnostics = analyze_file_body(path, environment)
        end
        @file_dependencies[path] = record
        diagnostics
      end

      def analyze_file_body(path, environment) # rubocop:disable Metrics/MethodLength
        parse_result = parse_source(path)
        unless parse_result.errors.empty?
          return [] if ErbTemplateDetector.template?(parse_result)

          return parse_diagnostics(path, parse_result)
        end

        scope = seed_project_scope(Scope.empty(environment: environment, source_path: path))
        # ADR-24 slice 4a/4 — record unresolved implicit-self calls during the
        # typing pass ONLY (not CheckRules, whose own `type_of` queries would
        # otherwise re-trigger the choke-point). `self_call_misses` feeds the
        # `call.self-undefined-method` collector; the recorder is inert unless
        # the rule is active or `record_self_calls:` opted in.
        index = nil
        self_call_record = with_self_call_recording(path) do
          index = Inference::ScopeIndexer.index(parse_result.value, default_scope: scope)
        end
        diagnostics = CheckRules.diagnose(
          path: path,
          root: parse_result.value,
          scope_index: index,
          self_call_misses: self_call_record ? self_call_record.calls : [],
          comments: parse_result.comments,
          disabled_rules: @configuration.disabled_rules
        )
        diagnostics += plugin_emitted_diagnostics(path, parse_result.value, scope)
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

      # ADR-24 slice 4a — runs `block` (the typing pass) with the self-call
      # recorder active when either the test-only `record_self_calls:` flag is
      # set or the `call.self-undefined-method` rule resolves to a firing
      # severity. Returns the frozen {SelfCallResolutionRecorder::Record}, or
      # nil when recording is inactive (the common path — one integer read).
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

      # Memoised: the rule fires only when its resolved severity is not `:off`
      # and it is not in `disable:`. Default profiles map it to `:off`, so a
      # normal run never activates the recorder (pending the external WD4
      # corpus FP gate — see ADR-24 § "Slice 4"); a project opts in via
      # `severity_overrides:`.
      def self_undefined_rule_active?
        return @self_undefined_rule_active unless @self_undefined_rule_active.nil?

        rule = CheckRules::RULE_SELF_UNDEFINED_METHOD
        @self_undefined_rule_active =
          if @configuration.disabled_rules.include?(rule) || @configuration.disabled_rules.include?("call")
            false
          else
            Configuration::SeverityProfile.resolve(
              rule: rule, authored_severity: :warning,
              profile: @configuration.severity_profile, overrides: @configuration.severity_overrides
            ) != :off
          end
      end

      # v0.0.2 #10 — fail-soft fallback explanation. When
      # `--explain` is set the runner additionally walks the
      # file with `Rigor::Inference::CoverageScanner` and emits
      # one `:info` diagnostic per directly-unrecognized node,
      # naming the node class and the type the engine fell back
      # to. The CoverageScanner is the canonical "first-event-
      # per-node" probe: it already filters out pass-through
      # wrappers (`ProgramNode`, `StatementsNode`,
      # `ParenthesesNode`) so the explain stream is attributable
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
