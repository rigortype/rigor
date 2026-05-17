# frozen_string_literal: true

require_relative "../environment"
require_relative "../cache/store"
require_relative "../analysis/runner"

module Rigor
  module LanguageServer
    # Per-session cache of the project-wide analyzer state the LSP
    # reads on every request — chiefly the `Environment` (with its
    # ~100-300ms RBS env build), a read-only `Cache::Store` that
    # lets the runner hit the on-disk RBS cache without writing
    # back, and (since the pre-pass cache slice) a frozen
    # {Rigor::Analysis::ProjectScan} snapshot covering the
    # plugin registry, dependency-source index, and pre-pass
    # scanner outputs.
    #
    # The pre-pass scan lets `DiagnosticPublisher#run_analysis`
    # build a `Runner` with `prebuilt:` so per-buffer publishes
    # skip plugin `#prepare`, the synthetic-method scanner, the
    # project-patched scanner, and the dependency-source walker.
    # For projects with substrate plugins / opt-in dependency
    # source / sizeable `pre_eval:` configuration this cuts
    # publish wall time substantially — for the trivial case
    # the savings are small (the per-publish path is already
    # ≈2ms once Environment is warm).
    #
    # Invalidation:
    # - `#invalidate!` drops the cached environment AND project
    #   scan + bumps the generation counter; the next reader
    #   rebuilds. Watched-file changes
    #   (`workspace/didChangeWatchedFiles`) and configuration
    #   refreshes (`workspace/didChangeConfiguration`) both
    #   trigger this — the next publish observes the new
    #   project state.
    # - The cache store is NOT invalidated on file change — it's
    #   content-addressed (digests over file contents), so stale
    #   entries naturally lose their key match. We DO keep a single
    #   Store instance across the session so the in-process memo
    #   serves repeat reads cheaply.
    #
    # Editor-mode trade-off: the cached `project_scan` was built
    # without any `buffer:` binding so scanners observed on-disk
    # bytes for every project file (including the file the user
    # is editing right now). Edits to a file that itself declares
    # `Plugin::Macro::HeredocTemplate` consumers or
    # `pre_eval:`-listed methods are not visible until a
    # watched-file change triggers `invalidate!`. The common
    # editor flow (save → file watch fires → publish) refreshes
    # automatically; the rare in-flight edit to a substrate-DSL
    # file is the documented edge case.
    class ProjectContext
      attr_reader :configuration, :generation

      def initialize(configuration:)
        @configuration = configuration
        @generation = 0
        @environment = nil
        @cache_store = nil
        @project_scan = nil
      end

      # Returns the cached `Rigor::Environment` for this session,
      # building it on first access. Subsequent calls return the
      # same instance until `#invalidate!` drops the cache.
      def environment
        @environment ||= Environment.for_project(
          libraries: @configuration.libraries,
          signature_paths: @configuration.signature_paths,
          cache_store: cache_store
        )
      end

      # Returns the per-session read-only `Cache::Store`. Read-only
      # so multiple LSP sessions against the same project don't
      # race on cache writes — same contract editor mode v1 already
      # uses for the CLI `--tmp-file` path.
      def cache_store
        @cache_store ||= Cache::Store.new(root: @configuration.cache_path, read_only: true)
      end

      # Returns the cached {Rigor::Analysis::ProjectScan} for this
      # session, building it lazily by spinning up a project-only
      # `Runner` (no buffer binding, no `paths` override) and
      # calling `#prepare_project_scan`. The cold build pays the
      # full pre-pass cost once per generation; every subsequent
      # `Runner.new(prebuilt: project_scan)` skips it.
      def project_scan
        @project_scan ||= build_project_scan
      end

      # Drops every cached collaborator and bumps the generation.
      # The next reader rebuilds from scratch. Triggered by
      # `workspace/didChangeWatchedFiles` for project source files
      # and by `workspace/didChangeConfiguration`.
      def invalidate!
        @generation += 1
        @environment = nil
        @project_scan = nil
        # Cache store stays — it's content-addressed; a stale env
        # build won't be served because the file digest mixed into
        # the cache key has changed.
        nil
      end

      private

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
