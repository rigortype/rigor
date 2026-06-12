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
require_relative "runner/run_snapshots"
require_relative "runner/project_pre_passes"
require_relative "runner/pool_coordinator"
require_relative "runner/diagnostic_aggregator"

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
        # nil-guards. The four end-of-pass snapshots (RBS class /
        # signature-path tables, synthesized-namespace names,
        # `rigor:v1:conforms-to` results) live in one shared mutable
        # {RunSnapshots} sink so the analysis path that writes them and
        # the run / aggregator code that reads them stay in separate
        # collaborators without a back-reference cycle.
        @snapshots = RunSnapshots.new
        @cached_plugin_prepare_diagnostics = [].freeze
        @project_discovered_classes = {}.freeze
        @project_discovered_def_nodes = {}.freeze
        @project_discovered_singleton_def_nodes = {}.freeze
        @project_discovered_def_sources = {}.freeze
        @project_discovered_superclasses = {}.freeze
        @project_discovered_includes = {}.freeze
        @project_discovered_class_sources = {}.freeze
        @project_discovered_method_visibilities = {}.freeze
        @project_discovered_methods = {}.freeze
        @project_data_member_layouts = {}.freeze
        build_collaborators
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
        @snapshots.reset_for_run

        if @prebuilt
          adopt_prebuilt_project_scan(@prebuilt)
        else
          run_project_pre_passes(expansion: expansion)
        end

        diagnostics = compute_run_diagnostics(expansion)

        Result.new(
          diagnostics: @diagnostic_aggregator.apply_severity_profile(diagnostics),
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

        environment = @pool_coordinator.resolve_sequential_environment(source_files: target_files(expansion))
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
        diagnostics = @diagnostic_aggregator.pre_file_diagnostics(expansion)
        # ADR-46 — record which project files this run actually analyzed
        # (the `analyze_only` subset, or all of them). The incremental
        # orchestrator serves every analyzed-but-not-affected file from the
        # per-file cache, so it needs the full analyzed set to subtract the
        # affected closure from.
        targets = target_files(expansion)
        @analyzed_files = targets
        diagnostics += @pool_coordinator.analyze_files(targets, environment: environment)
        diagnostics += @diagnostic_aggregator.rbs_synthesized_namespace_diagnostics
        diagnostics += @diagnostic_aggregator.conforms_to_diagnostics
        diagnostics += @diagnostic_aggregator.rbs_extended_reporter_diagnostics
        diagnostics += @diagnostic_aggregator.boundary_cross_diagnostics
        diagnostics + @diagnostic_aggregator.source_rbs_synthesis_diagnostics
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

      # Internal: copies a {ProjectPrePasses::Result} bundle onto the
      # runner's ivars in the assignment order the original inline
      # pre-pass body used, so every downstream reader (per-file
      # analysis seed, pool environment build, diagnostic aggregator)
      # sees the same ivar surface. The prebuilt path leaves the
      # discovery tables at their frozen-empty constructor defaults
      # (the bundle carries `nil` for them, matching the original
      # adopt path that never touched them).
      def apply_pre_passes_result(result) # rubocop:disable Metrics/AbcSize
        @plugin_registry = result.plugin_registry
        @dependency_source_index = result.dependency_source_index
        @cached_plugin_prepare_diagnostics = result.cached_plugin_prepare_diagnostics
        @synthetic_method_index = result.synthetic_method_index
        @project_patched_methods = result.project_patched_methods
        @pre_eval_diagnostics_from_scanner = result.pre_eval_diagnostics_from_scanner
        @project_discovered_classes = result.discovered_classes if result.discovered_classes
        @project_discovered_def_nodes = result.discovered_def_nodes if result.discovered_def_nodes
        if result.discovered_singleton_def_nodes
          @project_discovered_singleton_def_nodes = result.discovered_singleton_def_nodes
        end
        @project_discovered_def_sources = result.discovered_def_sources if result.discovered_def_sources
        @project_discovered_superclasses = result.discovered_superclasses if result.discovered_superclasses
        @project_discovered_includes = result.discovered_includes if result.discovered_includes
        @project_discovered_class_sources = result.discovered_class_sources if result.discovered_class_sources
        if result.discovered_method_visibilities
          @project_discovered_method_visibilities = result.discovered_method_visibilities
        end
        @project_discovered_methods = result.discovered_methods if result.discovered_methods
        @project_data_member_layouts = result.data_member_layouts if result.data_member_layouts
      end
      private :run_project_pre_passes, :adopt_prebuilt_project_scan, :apply_pre_passes_result

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

      # Wires the three responsibility collaborators. Called at the end
      # of construction (after every state ivar is seeded). The per-run
      # varying state (the plugin registry, dependency-source / scanner
      # indexes, prepare-diagnostic snapshot, and the four end-of-pass
      # snapshots) is reached through reader procs so each collaborator
      # observes the live ivar value at call time without a
      # back-reference cycle. The reporter accumulators and the
      # {RunSnapshots} sink are shared mutable instances.
      def build_collaborators # rubocop:disable Metrics/MethodLength
        @pre_passes = ProjectPrePasses.new(
          configuration: @configuration, cache_store: @cache_store, buffer: @buffer,
          plugin_requirer: @plugin_requirer, pool_mode: -> { pool_mode? }
        )
        @pool_coordinator = PoolCoordinator.new(
          configuration: @configuration, cache_store: @cache_store, explain: @explain,
          workers: @workers, collect_stats: @collect_stats, buffer: @buffer,
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
          conformance_results_snapshot: -> { @snapshots.conformance_results }
        )
      end

      # ADR-15 Phase 4b — pool mode is enabled when `@workers > 0`.
      # Editor mode (`buffer:` non-nil) silently overrides pool
      # mode to sequential. The real decision lives on
      # {PoolCoordinator}; the predicate stays on the runner because
      # `run_result_cacheable?` consults it (and a spec exercises it
      # via `send`).
      def pool_mode?
        @pool_coordinator.pool_mode?
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
      def plugin_emitted_diagnostics(path, root, scope, node_results)
        return [] if @plugin_registry.empty?

        @plugin_registry.contribution_index.for_file_diagnostics.flat_map do |plugin|
          collect_plugin_diagnostics(plugin, path, root, scope, node_results[plugin])
        end
      end

      # ADR-52 WD4 + ADR-53 B4 — one engine-owned AST walk per file
      # dispatches each node to every matching (plugin, rule) AND drives
      # the built-in node collectors (`node_collectors`), so the file is
      # walked once for both. The per-plugin results are bucketed in
      # registry order so plugin emission stays plugin-major
      # (byte-identical with the old per-plugin walk); the collectors are
      # populated in place for `diagnose` to consume.
      #
      # When no plugin declares a node rule, the walk still runs to drive
      # the collectors (the converged path replaces the standalone
      # `RuleWalk.run`); `node_collectors` nil means a caller that does
      # not need built-in collection from this walk.
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
        # A node-rule context/rule raise isolates the whole plugin's
        # node-rule contribution, matching the old combined per-plugin
        # rescue (which discarded `diagnostics_for_file` output too).
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
        tables = project_scope_seed_tables
        return scope if tables.empty?

        scope.with_discovery(scope.discovery.with(**tables))
      end

      # The cross-file pre-pass tables {#seed_project_scope} applies, as a
      # plain Hash so the fork-pool path can hand the same seed to its
      # {WorkerSession} (whose per-file scopes would otherwise miss every
      # cross-file def — ADR-15 sequential-equivalence contract).
      def project_scope_seed_tables
        tables = {}
        tables[:discovered_classes] = @project_discovered_classes unless @project_discovered_classes.empty?
        tables[:discovered_def_nodes] = @project_discovered_def_nodes unless @project_discovered_def_nodes.empty?
        unless @project_discovered_singleton_def_nodes.empty?
          tables[:discovered_singleton_def_nodes] = @project_discovered_singleton_def_nodes
        end
        tables[:discovered_def_sources] = @project_discovered_def_sources unless @project_discovered_def_sources.empty?
        unless @project_discovered_superclasses.empty?
          tables[:discovered_superclasses] = @project_discovered_superclasses
        end
        tables[:discovered_includes] = @project_discovered_includes unless @project_discovered_includes.empty?
        unless @project_discovered_method_visibilities.empty?
          tables[:discovered_method_visibilities] = @project_discovered_method_visibilities
        end
        tables[:discovered_methods] = @project_discovered_methods unless @project_discovered_methods.empty?
        tables[:data_member_layouts] = @project_data_member_layouts unless @project_data_member_layouts.empty?
        # ADR-46 slice 1 — the class-declaration source map is read only by
        # the ancestry accessors during dependency recording, so seed it
        # only when recording is on; a normal run never carries it.
        if @record_dependencies && !@project_discovered_class_sources.empty?
          tables[:discovered_class_sources] = @project_discovered_class_sources
        end
        tables
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

      # ADR-53 B4 — the built-in node collectors and the plugin node rules
      # share ONE traversal of the file. The collectors are built here (they
      # need the completed `index`) and populated by the converged plugin
      # walk; `node_results` carries the per-plugin node-rule output. Both
      # the built-in `diagnose` output and the plugin diagnostics are then
      # built from that single walk's results.
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
