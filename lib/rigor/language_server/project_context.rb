# frozen_string_literal: true

require "tempfile"

require_relative "../environment"
require_relative "../scope"
require_relative "../project_environment"
require_relative "../cache/store"
require_relative "../analysis/runner"
require_relative "../analysis/incremental_session"
require_relative "../cache/incremental_snapshot"
require_relative "../effects/identity"
require_relative "../analysis/path_expansion"
require_relative "../protection/discovery_seed"

module Rigor
  module LanguageServer
    # Per-session cache of the project-wide analyzer state the LSP reads on every request — chiefly the
    # `Environment` (with its ~100-300ms RBS env build), a read-only `Cache::Store` that lets the runner hit
    # the on-disk RBS cache without writing back, and (since the pre-pass cache slice) a frozen
    # {Rigor::Analysis::ProjectScan} snapshot covering the plugin registry, dependency-source index,
    # pre-pass scanner outputs and (since #1038) the compiled template-unit index.
    #
    # The pre-pass scan lets `DiagnosticPublisher#run_analysis` build a `Runner` with `prebuilt:` so per-buffer
    # publishes skip plugin `#prepare`, the synthetic-method scanner, the project-patched scanner, and the
    # dependency-source walker — and, since #1038, the template-unit transform: a publish recompiles only a
    # template that moved on disk since the scan was built (plus the buffer's own, always), rather than every
    # view in the project. For projects with substrate plugins / opt-in dependency source / sizeable
    # `pre_eval:` configuration this cuts publish wall time substantially — for the trivial case the savings
    # are small (the per-publish path is already ≈2ms once Environment is warm).
    #
    # Invalidation:
    # - Every whole-project round (`#project_diagnostics`) re-reads the configuration and compares the
    #   incremental snapshot fingerprint and the `effects:` identity with the ones its session was primed with,
    #   re-baselining on any change — so no file watcher or `didChangeConfiguration` is needed for
    #   `.rigor.yml`, `sig/`, `pre_eval:` or lockfile edits (#1613).
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

      # `configuration_loader` re-reads the configuration (e.g. `-> { Configuration.load(path) }`); a save round
      # calls it so an edit to `.rigor.yml` (or a file it `includes:`) reaches the server without a restart. Nil
      # keeps the configuration the context was built with.
      def initialize(configuration:, configuration_loader: nil)
        @configuration = configuration
        @configuration_loader = configuration_loader
        @primed_key = nil
        @buffer_sources = {}
        @disk_feature_files = nil
        @disk_sig_names = nil
        @environment_features = nil
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
          # Issue #1700 — the configured paths' files overlaid with the open buffers; {#note_buffers}
          # rebuilds this when an edit or a save changes the set.
          required_features: (@environment_features = required_features),
          **ProjectEnvironment.dependency_discovery_options(@configuration)
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

      # Issue #2147 — the cross-file discovery tables a per-buffer publish seeds its `Runner` with
      # (`discovery_seed:`, #260). A `prebuilt:` runner runs no discovery pass of its own, so without them every
      # class another file declares reads as an external ancestor and a publish answers differently from
      # `rigor check` over the same tree. The per-file bundles are walked once per generation; each publish
      # re-folds them with `buffer`'s file re-walked from the buffer's bytes
      # ({Protection::DiscoverySeed.tables_for_buffer}), so the buffer's own declarations win over its on-disk
      # ones, and a file whose bytes on disk moved since the bundles were built is re-walked too (its digest no
      # longer matches).
      #
      # The buffer's file is matched by its real path and handed to the fold under the buffer's own spelling: the
      # binding substitutes bytes only for a path spelled exactly as its logical path (the URI's absolute path),
      # while the configured paths may be relative (`lib`, the default) or reach the file through a symlink.
      def discovery_seed_for(buffer)
        Protection::DiscoverySeed.tables_for_buffer(paths: discovery_paths_for(buffer), bundles: discovery_bundles,
                                                    buffer: buffer, constant_sources: true)
      end

      # Issue #2282 — the base scope an editor query (hover, completion, signature help) probes with: the same
      # cross-file discovery seed the diagnostic publisher hands its `Runner` ({#discovery_seed_for}), so a constant
      # or method another file defines answers what `rigor check` would. The seed fold reads the buffer through a
      # {Analysis::BufferBinding}, so `bytes` is staged in a tempfile for the call. An empty seed (no configured
      # files, or nothing discovered) leaves the bare single-file scope every query used before.
      def seeded_scope_for(path:, bytes:)
        base = Scope.empty(environment: environment)
        seed = Tempfile.create(["rigor-lsp-query-", ".rb"]) do |tmp|
          tmp.write(bytes)
          tmp.flush
          discovery_seed_for(Analysis::BufferBinding.new(logical_path: path, physical_path: tmp.path))
        end
        return base if seed.empty?

        base.with_discovery(base.discovery.with(**seed))
      end

      # Builds what {#discovery_seed_for} reads once per generation, so a fork batch's children inherit it instead
      # of each walking the project.
      def prepare_discovery_seed
        discovery_bundles
        discovery_real_paths
        nil
      end

      # Whole-project diagnostics for one save round (#246). The first call primes an in-process
      # {Analysis::IncrementalSession} — seeded from the on-disk snapshot a terminal
      # `rigor check --incremental` may have left, and otherwise from a full baseline; every later call is a
      # recheck against what changed on disk since.
      #
      # The session is never persisted. Its state lives as long as this context, which is what a long-running
      # server needs, and writing it would race exactly the way the read-only {#cache_store} exists to avoid.
      # Seeding is therefore one-directional: the terminal warms the server, not the reverse.
      #
      # Every round recomputes {Cache::IncrementalSnapshot.fingerprint} (the function the CLI's `--incremental`
      # keys its snapshot on — one input list) and compares it with the one the session was primed with. A
      # session's recheck only sees source-file digests, so an edit to a `pre_eval:` file, an auto-detected
      # `sig/*.rbs`, a lockfile or `.rigor.yml` would otherwise keep serving answers computed from the old
      # inputs until the server restarts (#1613). A change — including a fingerprint that newly cannot be
      # computed — drops the session and the world built from the old inputs and re-baselines, so the round equals
      # a cold run. The `effects:` identity rides along because `Configuration#to_h` omits `effects:`, so the
      # fingerprint alone does not move on an `effects:` edit. A fingerprint that was ALREADY uncomputable at
      # priming is not a change: that session keeps rechecking.
      # {#generation} is deliberately NOT bumped: the round that notices the change is itself computed from the
      # new inputs, and the publisher discards a round whose generation moved.
      def project_diagnostics
        reload_configuration
        fingerprint = current_fingerprint
        key = [fingerprint, Effects::Identity.digest(configuration: @configuration)]
        rebaseline if @session_primed && key != @primed_key
        session = (@incremental_session ||= build_incremental_session)
        return session.recheck.diagnostics if @session_primed

        @session_primed = true
        @primed_key = key
        diagnostics, = session.run_incremental(
          snapshot: Cache::IncrementalSnapshot.new(root: @configuration.cache_path),
          fingerprint: fingerprint,
          persist: false
        )
        diagnostics
      end

      # Issue #1700 — records the open buffers' text (absolute path => source) and rebuilds the environment
      # when it changes the {Environment::RequiredFeatures} set the current one was built with: a buffer that
      # gains or drops a `require "prime"` loads or unloads the vendored `prime` signatures. The server calls
      # it on every open, change, save and close; neither `didSave` nor a `.rb` edit reaches
      # `workspace/didChangeWatchedFiles`, which most clients send only for the files they were asked to watch.
      # The configured paths are read once per environment and only the buffers are re-scanned, so a keystroke
      # costs a substring test per open buffer.
      def note_buffers(sources)
        @buffer_sources = sources
        return if @environment.nil? || required_features == @environment_features

        invalidate!
      end

      # The required-feature set for the configured paths' files on disk, each open buffer read in place of its
      # file.
      def required_features
        disk = (@disk_feature_files ||= Environment::RequiredFeatures.feature_files(@configuration))
        scanned = disk.reject { |path, _| @buffer_sources.key?(path) }.values
        scanned += @buffer_sources.values.map { |source| Environment::RequiredFeatures.scan_source(source) }
        features = scanned.flat_map(&:first).uniq
        names = scanned.flat_map(&:last).to_set
        names.merge(@disk_sig_names ||= Environment::RequiredFeatures.sig_names(
          Environment::RequiredFeatures.configured_sig_paths(@configuration)
        ))
        Environment::RequiredFeatures.relevant(features, names).sort.freeze
      end

      # Drops every cached collaborator and bumps the generation. The next reader rebuilds from scratch.
      # Triggered by `workspace/didChangeWatchedFiles` for project source files and by
      # `workspace/didChangeConfiguration`.
      def invalidate!
        @generation += 1
        reset_world
      end

      private

      # Drops what was built from the previous inputs, without touching {#generation}.
      def reset_world
        @environment = nil
        @environment_features = nil
        @disk_feature_files = nil
        @disk_sig_names = nil
        @project_scan = nil
        @discovery_paths = nil
        @discovery_real_paths = nil
        @discovery_bundles = nil
        # The session's per-file cache was computed against the old environment / project scan, so it cannot
        # outlive them. The next save round primes a fresh one.
        @incremental_session = nil
        @session_primed = false
        @primed_key = nil
        # Cache store stays — it's content-addressed; a stale env build won't be served because the file
        # digest mixed into the cache key has changed.
        nil
      end

      # A changed configuration may also move `cache_path`, so the store goes too (unlike {#invalidate!}).
      def rebaseline
        reset_world
        @cache_store = nil
      end

      def current_fingerprint
        Cache::IncrementalSnapshot.fingerprint(configuration: @configuration, roots: @configuration.paths)
      end

      # A load that raises (a half-typed `.rigor.yml`) keeps the previous configuration: the editor must not
      # lose its diagnostics to a transient parse error, and the next round retries.
      def reload_configuration
        return unless @configuration_loader

        @configuration = @configuration_loader.call
      rescue StandardError
        nil
      end

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

      # The configured project files, expanded as `rigor check` expands its configured paths.
      def discovery_paths
        @discovery_paths ||= Analysis::PathExpansion.configured_files(@configuration).freeze
      end

      # Every entry that reaches the buffer's file is respelled, so a file configured under two roots (`lib` and a
      # symlink to it) is not folded from disk through the second.
      def discovery_paths_for(buffer)
        Protection::DiscoverySeed.respell_for_buffer(discovery_paths, buffer, real_paths: discovery_real_paths)
      end

      def discovery_real_paths
        @discovery_real_paths ||= discovery_paths.map { |path| Rigor::Analysis::BufferBinding.real_path(path) }.freeze
      end

      def discovery_bundles
        @discovery_bundles ||= Protection::DiscoverySeed.bundles(paths: discovery_paths)
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
