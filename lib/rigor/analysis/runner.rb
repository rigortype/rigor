# frozen_string_literal: true

require "prism"

require_relative "../environment"
require_relative "../scope"
require_relative "../cache/store"
require_relative "../plugin"
require_relative "../rbs_extended/reporter"
require_relative "../reflection"
require_relative "../type/combinator"
require_relative "../inference/coverage_scanner"
require_relative "../inference/scope_indexer"
require_relative "../inference/synthetic_method_scanner"
require_relative "../inference/project_patched_scanner"
require_relative "../inference/method_dispatcher/file_folding"
require_relative "check_rules"
require_relative "dependency_source_inference"
require_relative "diagnostic"
require_relative "result"
require_relative "run_stats"
require_relative "worker_session"

module Rigor
  module Analysis
    class Runner # rubocop:disable Metrics/ClassLength
      RUBY_GLOB = "**/*.rb"
      DEFAULT_CACHE_ROOT = ".rigor/cache"

      attr_reader :cache_store, :plugin_registry, :dependency_source_index,
                  :rbs_extended_reporter, :boundary_cross_reporter

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
      def initialize(configuration:, explain: false,
                     cache_store: Cache::Store.new(root: DEFAULT_CACHE_ROOT),
                     plugin_requirer: nil, workers: 0, collect_stats: true)
        @configuration = configuration
        @explain = explain
        @cache_store = cache_store
        @plugin_requirer = plugin_requirer
        @workers = workers
        @collect_stats = collect_stats
        @plugin_registry = Plugin::Registry::EMPTY
        @dependency_source_index = DependencySourceInference::Index::EMPTY
        @rbs_extended_reporter = RbsExtended::Reporter.new
        @boundary_cross_reporter = DependencySourceInference::BoundaryCrossReporter.new
      end

      # Walks every Ruby file under `paths`, parses it, builds a
      # per-node scope index through
      # `Rigor::Inference::ScopeIndexer`, and runs the
      # `Rigor::Analysis::CheckRules` catalogue over it. Returns
      # a `Rigor::Analysis::Result` aggregating every produced
      # diagnostic plus any Prism parse errors. The Environment
      # is built once at run start through `Environment.for_project`
      # so all files share the same RBS load.
      def run(paths = @configuration.paths) # rubocop:disable Metrics/AbcSize
        Inference::MethodDispatcher::FileFolding.fold_platform_specific_paths =
          @configuration.fold_platform_specific_paths

        wall_started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        target_ruby_error = validate_target_ruby
        return Result.new(diagnostics: [target_ruby_error]) if target_ruby_error

        @plugin_registry = load_plugins
        @dependency_source_index = DependencySourceInference::Builder.build(@configuration.dependencies)
        expansion = expand_paths(paths)
        @class_decl_paths_snapshot = {}.freeze
        @signature_paths_snapshot = []
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
          fact_store: shared_fact_store
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
        pre_eval_outcome = Inference::ProjectPatchedScanner.scan(existing_pre_eval)
        @project_patched_methods = pre_eval_outcome.registry
        @pre_eval_diagnostics_from_scanner = pre_eval_outcome.diagnostics

        diagnostics = pre_file_diagnostics(expansion)
        diagnostics += analyze_files(expansion.fetch(:files))
        diagnostics += rbs_extended_reporter_diagnostics
        diagnostics += boundary_cross_diagnostics

        Result.new(
          diagnostics: apply_severity_profile(diagnostics),
          stats: @collect_stats ? build_run_stats(wall_started_at: wall_started_at, expansion: expansion) : nil
        )
      end

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
      def analyze_files(files)
        return [] if files.empty?

        if pool_mode?
          analyze_files_in_pool(files)
        else
          environment = build_runner_environment
          result = files.flat_map { |path| analyze_file(path, environment) }
          if @collect_stats
            loader = environment.rbs_loader
            @class_decl_paths_snapshot = loader&.class_decl_paths || {}.freeze
            @signature_paths_snapshot = loader&.signature_paths || [].freeze
          end
          result
        end
      end

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
        prepare = pool_mode? ? [] : (@cached_plugin_prepare_diagnostics || [])
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

      def pool_mode?
        @workers.is_a?(Integer) && @workers.positive?
      end

      # Coordinator-side Environment used by the sequential code
      # path. Pool mode builds one Environment per worker inside
      # the worker Ractor's body instead.
      def build_runner_environment
        Environment.for_project(
          libraries: @configuration.libraries,
          signature_paths: @configuration.signature_paths,
          cache_store: @cache_store,
          plugin_registry: @plugin_registry,
          dependency_source_index: @dependency_source_index,
          rbs_extended_reporter: @rbs_extended_reporter,
          boundary_cross_reporter: @boundary_cross_reporter,
          bundler_bundle_path: @configuration.bundler_bundle_path,
          bundler_auto_detect: @configuration.bundler_auto_detect,
          bundler_lockfile: @configuration.bundler_lockfile,
          rbs_collection_lockfile: @configuration.rbs_collection_lockfile,
          rbs_collection_auto_detect: @configuration.rbs_collection_auto_detect,
          synthetic_method_index: @synthetic_method_index,
          project_patched_methods: @project_patched_methods
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
      def analyze_files_in_pool(files) # rubocop:disable Metrics/MethodLength,Metrics/AbcSize,Metrics/CyclomaticComplexity
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

        pool = Array.new(@workers) do
          Ractor.new(configuration, cache_root, blueprints, explain) do |configuration, cache_root, blueprints, explain|
            cache_store = cache_root ? Rigor::Cache::Store.new(root: cache_root) : nil
            session = Rigor::Analysis::WorkerSession.new(
              configuration: configuration,
              cache_store: cache_store,
              plugin_blueprints: blueprints,
              explain: explain
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
        snapshot = @class_decl_paths_snapshot || {}.freeze
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
      def plugin_emitted_diagnostics(path, root, scope)
        return [] if @plugin_registry.empty?

        @plugin_registry.plugins.flat_map do |plugin|
          collect_plugin_diagnostics(plugin, path, root, scope)
        end
      end

      def collect_plugin_diagnostics(plugin, path, root, scope)
        raw = plugin.diagnostics_for_file(path: path, scope: scope, root: root)
        Array(raw).map { |diagnostic| stamp_plugin_diagnostic(diagnostic, plugin.manifest.id) }
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
          elsif File.file?(path) && path.end_with?(".rb")
            files << path
          elsif File.exist?(path)
            errors << path_error(path, "not a Ruby file (expected `.rb` or a directory)")
          else
            errors << path_error(path, "no such file or directory")
          end
        end
        { files: files, errors: errors }
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

      def analyze_file(path, environment) # rubocop:disable Metrics/MethodLength
        parse_result = Prism.parse_file(path, version: @configuration.target_ruby)
        return parse_diagnostics(path, parse_result) unless parse_result.errors.empty?

        scope = Scope.empty(environment: environment, source_path: path)
        index = Inference::ScopeIndexer.index(parse_result.value, default_scope: scope)
        diagnostics = CheckRules.diagnose(
          path: path,
          root: parse_result.value,
          scope_index: index,
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
