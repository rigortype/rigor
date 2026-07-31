# frozen_string_literal: true

require_relative "../environment"
require_relative "../cache/store"
require_relative "../analysis/runner"
require_relative "../analysis/incremental_session"
require_relative "../cache/incremental_snapshot"

module Rigor
  module LanguageServer
    # Per-session cache of the project-wide analyzer state the LSP reads on every request — chiefly the
    # `Environment` (with its ~100-300ms RBS env build), a read-only `Cache::Store` that lets the runner hit
    # the on-disk RBS cache without writing back, and (since the pre-pass cache slice) a frozen
    # {Rigor::Analysis::ProjectScan} snapshot covering the plugin registry, dependency-source index, and
    # pre-pass scanner outputs.
    #
    # The pre-pass scan lets `DiagnosticPublisher#run_analysis` build a `Runner` with `prebuilt:` so per-buffer
    # publishes skip plugin `#prepare`, the synthetic-method scanner, the project-patched scanner, and the
    # dependency-source walker. For projects with substrate plugins / opt-in dependency source / sizeable
    # `pre_eval:` configuration this cuts publish wall time substantially — for the trivial case the savings
    # are small (the per-publish path is already ≈2ms once Environment is warm).
    #
    # Invalidation:
    # - `#invalidate!` drops the cached environment AND project scan + bumps the generation counter; the next
    #   reader rebuilds. Watched-file changes (`workspace/didChangeWatchedFiles`) and configuration refreshes
    #   (`workspace/didChangeConfiguration`) both trigger this — the next publish observes the new project
    #   state.
    # - The cache store is NOT invalidated on file change — it's content-addressed (digests over file
    #   contents), so stale entries naturally lose their key match. We DO keep a single Store instance across
    #   the session so the in-process memo serves repeat reads cheaply.
    #
    # Editor-mode trade-off: the cached `project_scan` was built without any `buffer:` binding so scanners
    # observed on-disk bytes for every project file (including the file the user is editing right now). Edits
    # to a file that itself declares `Plugin::Macro::HeredocTemplate` consumers or `pre_eval:`-listed methods
    # are not visible until a watched-file change triggers `invalidate!`. The common editor flow (save → file
    # watch fires → publish) refreshes automatically; the rare in-flight edit to a substrate-DSL file is the
    # documented edge case.
    class ProjectContext
      # `generation` is the invalidation counter: a long-running save round (#246) captures it on entry and
      # discards its result if it moved, so diagnostics computed against a world that has since been
      # invalidated never reach the editor.
      attr_reader :configuration, :generation

      def initialize(configuration:)
        @configuration = configuration
        @generation = 0
        @environment = nil
        @cache_store = nil
        @project_scan = nil
        @incremental_session = nil
        @session_primed = false
      end

      # Returns the cached `Rigor::Environment` for this session, building it on first access. The build
      # includes the project's full scan state (plugin registry, dependency-source index, synthetic-method /
      # project-patched indexes — drawn from {#project_scan}) AND every Bundler / RBS-collection axis the
      # runner consults at build time, so the resulting env is bit-for-bit equivalent to what `Runner.run`
      # would have built on its own.
      #
      # `DiagnosticPublisher` passes this env through `Runner.new(environment: …)` so per-buffer publishes
      # share one instance instead of repeating the `Environment.for_project` build per call (bundler
      # discovery, RbsLoader construction, signature_paths composition). Subsequent calls return the same
      # instance until `#invalidate!` drops the cache.
      #
      # The runner attaches its own per-call reporter pair onto the shared env's `Reporters` slot at the start
      # of each `#analyze_files` — so diagnostic events stay scoped to a single publish and do NOT accumulate
      # across publishes.
      def environment
        @environment ||= Environment.for_project(
          libraries: @configuration.libraries,
          signature_paths: @configuration.signature_paths,
          cache_store: cache_store,
          plugin_registry: project_scan.plugin_registry,
          dependency_source_index: project_scan.dependency_source_index,
          synthetic_method_index: project_scan.synthetic_method_index,
          project_patched_methods: project_scan.project_patched_methods,
          bundler_bundle_path: @configuration.bundler_bundle_path,
          bundler_auto_detect: @configuration.bundler_auto_detect,
          bundler_lockfile: @configuration.bundler_lockfile,
          rbs_collection_lockfile: @configuration.rbs_collection_lockfile,
          rbs_collection_auto_detect: @configuration.rbs_collection_auto_detect
        )
      end

      # Returns the per-session read-only `Cache::Store`. Read-only so multiple LSP sessions against the same
      # project don't race on cache writes — same contract editor mode v1 already uses for the CLI
      # `--tmp-file` path.
      def cache_store
        @cache_store ||= Cache::Store.new(root: @configuration.cache_path, read_only: true)
      end

      # Returns the cached {Rigor::Analysis::ProjectScan} for this session, building it lazily by spinning up a
      # project-only `Runner` (no buffer binding, no `paths` override) and calling `#prepare_project_scan`. The
      # cold build pays the full pre-pass cost once per generation; every subsequent
      # `Runner.new(prebuilt: project_scan)` skips it.
      def project_scan
        @project_scan ||= build_project_scan
      end

      # Whole-project diagnostics for one save round (#246). The first call primes an in-process
      # {Analysis::IncrementalSession} — seeded from the on-disk snapshot a terminal
      # `rigor check --incremental` may have left, and otherwise from a full baseline; every later call is a
      # recheck against what changed on disk since.
      #
      # The session is never persisted. Its state lives as long as this context, which is what a long-running
      # server needs, and writing it would race exactly the way the read-only {#cache_store} exists to avoid.
      # Seeding is therefore one-directional: the terminal warms the server, not the reverse.
      def project_diagnostics
        session = (@incremental_session ||= build_incremental_session)
        return session.recheck.diagnostics if @session_primed

        @session_primed = true
        diagnostics, = session.run_incremental(
          snapshot: Cache::IncrementalSnapshot.new(root: @configuration.cache_path),
          fingerprint: Cache::IncrementalSnapshot.fingerprint(
            configuration: @configuration, roots: @configuration.paths
          ),
          persist: false
        )
        diagnostics
      end

      # Drops every cached collaborator and bumps the generation. The next reader rebuilds from scratch.
      # Triggered by `workspace/didChangeWatchedFiles` for project source files and by
      # `workspace/didChangeConfiguration`.
      def invalidate!
        @generation += 1
        @environment = nil
        @project_scan = nil
        # The session's per-file cache was computed against the old environment / project scan, so it cannot
        # outlive them. The next save round primes a fresh one.
        @incremental_session = nil
        @session_primed = false
        # Cache store stays — it's content-addressed; a stale env build won't be served because the file
        # digest mixed into the cache key has changed.
        nil
      end

      private

      # The session shares this context's warm Environment, so a round does not rebuild the RBS universe. It
      # deliberately does NOT share the prebuilt ProjectScan: a round runs after a save, i.e. after the file
      # on disk moved, and the scan is what a changed file invalidates.
      def build_incremental_session
        Analysis::IncrementalSession.new(
          configuration: @configuration,
          environment: environment,
          cache_store: cache_store
        )
      end

      def build_project_scan
        runner = Analysis::Runner.new(
          configuration: @configuration,
          cache_store: cache_store,
          collect_stats: false
        )
        runner.prepare_project_scan
      end
    end
  end
end
