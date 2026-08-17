# frozen_string_literal: true

require "fileutils"
require "json"
require "optionparser"

require_relative "../configuration"
require_relative "../config_audit"
require_relative "../analysis/result"
require_relative "../analysis/rule_catalog"
# The baseline filter runs on EVERY exit path — including the ADR-87 WD4 cache-HIT fast path, which skips
# `load_check_dependencies` — so it must be a load-time require. It pulls only YAML, never the engine.
require_relative "../analysis/baseline"
require_relative "../runtime/jit"
require_relative "command"
require_relative "options"
require_relative "diagnostic_formats"
require_relative "../ci_detector"
# ADR-87 WD4 — `coverage_scan` and `check_runner_factory` both pull the inference engine, so they are required
# lazily (in `compute_coverage` / `build_check_runner`) rather than at load time: an ordinary check whose
# result the run-cache probe serves must reach the hit verdict without `rigor/inference` in $LOADED_FEATURES.

module Rigor
  class CLI
    # Executes `rigor check` — the analyzer's primary command.
    #
    # The other subcommands delegate to a `CLI::Command` subclass once they grow beyond a few lines; `check` is the
    # largest of them, owning option parsing, the baseline filter (ADR-22), the incremental modes (ADR-46), cache-stats
    # reporting, editor mode, the CI-native output formats (ADR-51), and the diagnostic-only / heap / budget appendices.
    # Keeping it in its own class follows the same dispatch-vs-implementation split the rest of the CLI uses and keeps
    # `Rigor::CLI` focused on dispatch.
    #
    # The class-length budget is relaxed (as on `Rigor::CLI` itself) because `check` aggregates several independent
    # concerns that are clearer read together than split across micro-classes.
    class CheckCommand < Command # rubocop:disable Metrics/ClassLength
      # @return [Integer] CLI exit status.
      def run # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
        # Arm deferred YJIT enablement before any analysis work: the deadline
        # thread only fires once a run outlasts the amortization window, so a
        # short check finishes before it ever pays JIT compile cost while a
        # long run JITs its dominant tail (Runtime::Jit).
        Runtime::Jit.enable_after(Runtime::Jit.deadline_seconds)
        # ADR-87 WD4 — parse options + resolve config WITHOUT the inference engine, so the run-cache hit probe
        # can run first. The heavy engine (`load_check_dependencies`) loads only on a miss / non-cacheable run.
        options = parse_check_options
        buffer = Options.resolve_buffer_binding(options, err: @err)
        return CLI::EXIT_USAGE if buffer == :usage_error

        configuration = load_check_configuration(options)
        configuration = apply_bleeding_edge_override(configuration, options)
        config_warnings = warn_unresolved_config(configuration)
        cache_root = configuration.cache_path
        handle_clear_cache(cache_root) if options.fetch(:clear_cache)

        # ADR-87 WD4 — try to serve the whole run from the ADR-45 cache before booting the engine. A hit boots
        # only CLI + config + cache + digest code (no `rigor/inference`), skipping the plugin prepass + env
        # build entirely.
        probed = try_run_cache_hit(configuration, options, buffer, cache_root)
        return finalize_cache_hit(probed, configuration, options, config_warnings) unless probed.nil?

        load_check_dependencies
        special = dispatch_special_check_mode(configuration, options, cache_root, buffer)
        return special unless special.nil?

        invocation = invoke_check(
          configuration: configuration, options: options,
          buffer: buffer, cache_root: cache_root
        )
        runner = invocation.runner
        raw_result = invocation.result
        result = apply_baseline_filter(raw_result, configuration, options)

        coverage = compute_coverage(runner, configuration, options)
        write_result(result, options.fetch(:format), coverage: coverage, config_warnings: config_warnings)
        emit_ci_detected_output(result, options)
        write_run_stats(result.stats) if result.stats
        write_trace_appendices
        runner.cache_store&.evict!
        write_cache_stats(cache_root, runner.cache_store) if options.fetch(:cache_stats)

        exit_code = result.success? ? 0 : 1
        exit_code = 1 if baseline_strict_violation?(raw_result.diagnostics, configuration, options)
        exit_code
      end

      private

      # ADR-87 WD4 — attempt the boot-slimming run-cache hit. Returns the cached {Analysis::Result} (severity
      # profile applied, no stats — matching a cache-served `Runner#run`) on a hit, or nil to fall through to
      # the full engine path. Only an ordinary sequential check whose result IS cache-served the same way is
      # eligible; every other mode (below) declines so the full path handles it unchanged.
      def try_run_cache_hit(configuration, options, buffer, cache_root)
        return nil unless run_cache_hit_eligible?(configuration, options, buffer)

        require_relative "../analysis/run_cache_probe"
        Analysis::RunCacheProbe.new(
          configuration: configuration, cache_root: cache_root, explain: options.fetch(:explain)
        ).serve(@argv.empty? ? configuration.paths : @argv)
      end

      # The probe is eligible only for a run the ADR-45 result cache actually serves: a writable cache (not
      # `--no-cache`), no editor buffer, sequential (pool runs are not result-cacheable), and no mode needing
      # the engine (`--coverage` / `--incremental` / `--verify-incremental`) or the runner's own reporting
      # (`--cache-stats`, the `RIGOR_*_TRACE` dev probes). A wrongly-permitted run still MISSES (the entry was
      # never written its way) and falls through — the gate is an optimisation, never a soundness boundary.
      def run_cache_hit_eligible?(configuration, options, buffer)
        buffer.nil? &&
          !options.fetch(:no_cache) && !options.fetch(:coverage) && !options.fetch(:cache_stats) &&
          !options.fetch(:incremental) && !options.fetch(:verify_incremental) &&
          !pool_workers_configured?(options, configuration) &&
          ENV["RIGOR_BUDGET_TRACE"].to_s.empty? && ENV["RIGOR_HEAP_TRACE"].to_s.empty?
      end

      # Any signal that per-file analysis would run in a worker pool (CLI `--workers`, the env override, or the
      # config default). Deliberately over-declines (a false positive only forgoes the fast lane); mirrors
      # {CheckRunnerFactory.resolve_workers} without requiring it (that pulls in the engine).
      def pool_workers_configured?(options, configuration)
        cli = options[:workers]
        return Integer(cli).positive? if cli

        env = ENV.fetch("RIGOR_RACTOR_WORKERS", nil)
        return Integer(env).positive? if env && !env.empty?

        configuration.parallel_workers.positive?
      rescue ArgumentError
        false
      end

      # ADR-87 WD4 — the engine-free tail for a cache-served hit: baseline filter + output + exit code,
      # mirroring the full path's tail but without stats (a hit collected none), trace appendices (they read
      # engine counters), or eviction (deferred to the next miss). `raw_result` is pre-baseline so the strict
      # gate reads the same diagnostics the full path would.
      def finalize_cache_hit(raw_result, configuration, options, config_warnings)
        result = apply_baseline_filter(raw_result, configuration, options)
        write_result(result, options.fetch(:format), config_warnings: config_warnings)
        emit_ci_detected_output(result, options)

        exit_code = result.success? ? 0 : 1
        exit_code = 1 if baseline_strict_violation?(raw_result.diagnostics, configuration, options)
        exit_code
      end

      # ADR-46 — the two incremental-analysis check modes both fully handle the run and return an exit code (so `run`
      # short-circuits); returns nil for an ordinary check.
      # A nil return means "not a special mode" — `run` continues with the ordinary check. Editor mode option B
      # also returns nil when it declines (no reusable snapshot), so the run falls back to single-file scope.
      def dispatch_special_check_mode(configuration, options, cache_root, buffer)
        if options.fetch(:verify_incremental)
          # The gate compares an incremental recheck against a full-run oracle, and a buffer makes the two
          # disagree by construction (the oracle reads the file on disk). Refusing beats the silent wrong
          # answer both incremental modes gave a buffer before #146.
          if buffer
            @err.puts("rigor: --verify-incremental cannot run against an editor buffer " \
                      "(--tmp-file / --instead-of); it compares against a full analysis of the files on disk.")
            return CLI::EXIT_USAGE
          end

          return run_verify_incremental(configuration, options, cache_root)
        end
        return run_incremental_check(configuration, options, cache_root, buffer) if options.fetch(:incremental)

        nil
      end

      # ADR-85 WD1 — the persistent cache the incremental session threads into each internal Runner so plugin
      # `#prepare` producers (the ADR-9/#74/ADR-60 WD3 record-and-validate caches) and the RBS environment serve
      # from disk across processes / rechecks rather than recomputing every invocation. Honors `--no-cache` (nil
      # = no store), mirroring {CheckRunnerFactory}. The whole-run ADR-45 result cache stays inert on these runs
      # — `Runner#run_result_cacheable?` excludes `record_dependencies` / `analyze_only`.
      def incremental_cache_store(configuration, options, cache_root)
        return nil if options.fetch(:no_cache)

        Cache::Store.new(root: cache_root, max_bytes: configuration.cache_max_bytes)
      end

      # ADR-46 — the incremental-analysis acceptance gate. Runs a baseline analysis (recording cross-file dependencies),
      # then re-analyzes a representative subset of files and serves the rest from the per-file cache (the body tier),
      # and asserts the merged diagnostics are byte-identical to a full `--no-cache` analysis. A mismatch means the
      # incremental machinery would serve a stale — manufactured — diagnostic, the soundness failure this gate exists to
      # catch. Prints a one-line PASS (exit 0) or the differing diagnostics (exit 1).
      def run_verify_incremental(configuration, options, cache_root)
        paths = @argv.empty? ? nil : @argv
        # ADR-85 WD1 — thread the store so the gate also asserts the cache-served producer path stays
        # byte-identical to the uncached full run (`verify_full_diagnostics` builds a nil-store runner).
        session = Analysis::IncrementalSession.new(
          configuration: configuration, paths: paths,
          cache_store: incremental_cache_store(configuration, options, cache_root)
        )
        session.baseline
        analyzed = session.analyzed_files

        # Every other file forms the re-analyzed subset, so the run exercises BOTH the subset-analysis path and the
        # cache-serving path.
        subset = analyzed.each_with_index.select { |_, index| index.even? }.map(&:first)
        incremental = normalize_diagnostics(session.reanalyze_subset(subset))
        full = normalize_diagnostics(verify_full_diagnostics(configuration, paths))

        report_verify_incremental(incremental, full, subset_size: subset.size, total: analyzed.size)
      end

      # ADR-46 — cross-process incremental analysis (`--incremental`). Derives the global fingerprint cheaply (no RBS
      # env build), loads the disk snapshot, and on a fingerprint hit re-analyzes only the files changed since the last
      # run (plus their dependents), serving the rest from the snapshot; on a miss runs a full baseline. Persists the
      # updated snapshot for the next invocation. Diagnostics are identical to a full run (the `--verify-incremental`
      # gate enforces this); the win is skipping per-file inference for unchanged files.
      def run_incremental_check(configuration, options, cache_root, buffer = nil)
        require_relative "check_runner_factory"
        paths = @argv.empty? ? nil : @argv
        fingerprint = Cache::IncrementalSnapshot.fingerprint(
          configuration: configuration, roots: paths || configuration.paths
        )
        snapshot = Cache::IncrementalSnapshot.new(root: cache_root)
        store = incremental_cache_store(configuration, options, cache_root)
        session = Analysis::IncrementalSession.new(
          configuration: configuration, paths: paths,
          cache_store: store,
          # ADR-46 — thread the same worker-count precedence the standard `check` path uses
          # (CLI `--workers` > `RIGOR_RACTOR_WORKERS` > `parallel.workers:` > 0) so the recheck's closure
          # re-analysis parallelises; the fork pool marshals dependency records back so the graph is sound.
          workers: CheckRunnerFactory.resolve_workers(options, configuration),
          buffer: buffer
        )

        return run_editor_mode_option_b(session, snapshot, fingerprint, configuration, options) if buffer

        diagnostics, warm = session.run_incremental(snapshot: snapshot, fingerprint: fingerprint)
        # The banner's file count comes from the session's analyzed set (cold analyses all; a warm recheck's
        # `@analyzed` advances to the current file set), so a dedicated probe Runner + `Dir.glob` is no longer
        # built just to size the banner (recon §3 — the analysis tree was expanded three times per recheck).
        @err.puts("rigor: --incremental #{warm ? 'warm — reused cached diagnostics' : 'cold — full analysis'} " \
                  "(#{session.analyzed_files.size} files)")
        emit_incremental_fact_surface_notes(session)
        write_incremental_cache_stats(session, cache_root, store) if options.fetch(:cache_stats)

        result = apply_baseline_filter(Analysis::Result.new(diagnostics: diagnostics, stats: nil), configuration,
                                       options)
        write_result(result, options.fetch(:format))
        result.success? ? 0 : 1
      end

      # Editor mode option B (#146) — `--incremental` plus an editor buffer. The whole project is in scope with
      # the buffer substituted for one file: the buffer's logical path and its dependents re-analyse, every
      # other file is served from the snapshot. Before this, the two flags together silently ignored the
      # buffer and analysed the file on disk, which is a wrong answer rather than a missing feature.
      #
      # The session never saves — the buffer's bytes exist only in the editor — so there is no warm state to
      # build up. That is why a snapshot it cannot reuse means falling back to option A (single-file scope,
      # the pre-#146 behaviour) instead of running a baseline that would repeat on the next keystroke. The
      # note tells the user how to get option B: warm the snapshot with a plain `rigor check --incremental`.
      def run_editor_mode_option_b(session, snapshot, fingerprint, configuration, options)
        result = session.run_buffer_recheck(snapshot: snapshot, fingerprint: fingerprint)
        if result.nil?
          @err.puts("rigor: --incremental has no reusable snapshot for this project; analysing the buffer " \
                    "alone (run `rigor check --incremental` once to enable whole-project editor mode).")
          return nil
        end

        @err.puts("rigor: --incremental editor mode — re-analysed #{result.affected.size} file(s), " \
                  "#{result.reused.size} served from cache")
        emit_incremental_fact_surface_notes(session)
        filtered = apply_baseline_filter(
          Analysis::Result.new(diagnostics: result.diagnostics, stats: nil), configuration, options
        )
        write_result(filtered, options.fetch(:format))
        filtered.success? ? 0 : 1
      end

      # ADR-88 WD1 — a one-line stderr note when the plugin fact surface (an ADR-9 fact, an ADR-60 producer
      # value, or an `incremental_state_fingerprint` hook) forced a full run: either it CHANGED since the
      # snapshot (a Sorbet sig edit, a schema change) or a contributing plugin declares NO fingerprint surface
      # (opaque — a full run every invocation). Both are the sound direction; the note explains why a recheck
      # was not warm.
      def emit_incremental_fact_surface_notes(session)
        opaque = session.opaque_plugin_ids
        unless opaque.empty?
          @err.puts("rigor: --incremental plugin#{'s' unless opaque.size == 1} #{opaque.sort.join(', ')} " \
                    "contribute call-site types with no incremental fingerprint surface; the snapshot cannot " \
                    "be reused (full analysis every run).")
        end
        return unless session.fact_surface_invalidated? && opaque.empty?

        @err.puts("rigor: --incremental plugin fact surface changed since the snapshot; ran a full analysis.")
      end

      # ADR-88 WD1 — `--incremental --cache-stats` surfaces the on-disk cache inventory (as a plain `check`
      # does) plus the fact-surface status line, so an operator can see whether a full run was fact-surface
      # driven. The plain `check` cache-stats path is bypassed by the incremental short-circuit, so it is
      # emitted here.
      def write_incremental_cache_stats(session, cache_root, store)
        write_cache_stats(cache_root, store)
        status =
          if !session.opaque_plugin_ids.empty?
            "opaque (#{session.opaque_plugin_ids.sort.join(', ')})"
          elsif session.fact_surface_invalidated?
            "changed — snapshot invalidated"
          else
            "unchanged"
          end
        @out.puts("  plugin fact surface: #{status}")
      end

      def verify_full_diagnostics(configuration, paths)
        runner = Analysis::Runner.new(configuration: configuration, cache_store: nil)
        (paths ? runner.run(paths) : runner.run).diagnostics
      end

      def normalize_diagnostics(diagnostics)
        diagnostics.map(&:to_h).sort_by do |hash|
          [hash["path"].to_s, hash["line"].to_i, hash["column"].to_i, hash["rule"].to_s, hash["message"].to_s]
        end
      end

      def report_verify_incremental(incremental, full, subset_size:, total:)
        if incremental == full
          @out.puts("rigor: --verify-incremental OK — incremental " \
                    "(#{subset_size}/#{total} files re-analyzed, rest from cache) " \
                    "matches full (#{full.size} diagnostics)")
          return 0
        end

        only_incremental = incremental - full
        only_full = full - incremental
        @err.puts("rigor: --verify-incremental FAILED — incremental and full diagnostics differ.")
        @err.puts("  incremental-only: #{only_incremental.size}, full-only: #{only_full.size}")
        (only_incremental + only_full).first(10).each do |hash|
          @err.puts("    #{hash['path']}:#{hash['line']}:#{hash['column']}: [#{hash['rule']}] #{hash['message']}")
        end
        1
      end

      # ADR-22 slice 5 — the `--baseline-strict` CI gate. When the flag is set, ANY baseline drift fails the run — not
      # only excess drift (a bucket over threshold, which already fails via the surfaced diagnostics) but also DEFICIT
      # drift (`actual < count`: the baseline has grown looser than the code and should be regenerated). A no-op, with a
      # stderr note, when no baseline is active — the flag never implicitly loads a baseline the config did not name
      # (WD2).
      def baseline_strict_violation?(raw_diagnostics, configuration, options)
        return false unless options.fetch(:baseline_strict)

        path = resolve_baseline_path(configuration, options)
        if path.nil?
          @err.puts("rigor: --baseline-strict given but no baseline is active; nothing to gate.")
          return false
        end

        baseline = Analysis::Baseline.load(path, project_root: Dir.pwd)
        return false if baseline.nil? || baseline.empty?

        drifted = baseline.audit(raw_diagnostics).reject { |row| row.status == :within }
        return false if drifted.empty?

        report_strict_drift(drifted, path)
        true
      rescue Analysis::Baseline::LoadError => e
        @err.puts("rigor: baseline load failed: #{e.message} (--baseline-strict gate skipped)")
        false
      end

      def report_strict_drift(rows, path)
        @err.puts("rigor: --baseline-strict — #{rows.size} bucket(s) drifted from #{path}:")
        rows.sort_by { |r| [r.bucket.file, r.bucket.rule] }.each do |row|
          delta = row.delta.positive? ? "+#{row.delta}" : row.delta.to_s
          @err.puts("  #{row.bucket.file}  [#{row.bucket.rule}]  " \
                    "#{row.bucket.count} → #{row.actual_count}  (Δ#{delta}, #{row.status})")
        end
        @err.puts("rigor: run `rigor baseline regenerate` to refresh the baseline.")
      end

      # ADR-22 — apply the baseline filter as the LAST step of the diagnostic pipeline (after `# rigor:disable`,
      # `severity_profile`, etc. — WD6). Resolution order follows WD2 (b):
      #
      #   1. --no-baseline on the CLI → no baseline.
      #   2. --baseline=PATH on the CLI → load that path.
      #   3. .rigor.yml's `baseline: <path>` → load that path.
      #   4. otherwise → no baseline.
      #
      # When the path resolves and loads successfully, the filter replaces `result.diagnostics` with the surfaced set
      # and writes a one-line summary to stderr (WD7) when any diagnostics were silenced. Load failures emit a warning
      # to stderr and fall through to "no baseline" (graceful degradation).
      def apply_baseline_filter(result, configuration, options)
        path = resolve_baseline_path(configuration, options)
        return result if path.nil?

        baseline = Analysis::Baseline.load(path, project_root: Dir.pwd)
        return result if baseline.nil?

        surfaced, silenced_count = baseline.filter(result.diagnostics)
        report_baseline_summary(silenced_count, path) if silenced_count.positive?
        Analysis::Result.new(diagnostics: surfaced, stats: result.stats)
      rescue Analysis::Baseline::LoadError => e
        @err.puts("rigor: baseline load failed: #{e.message} (continuing without baseline)")
        result
      end

      # WD2 (b) — resolve effective baseline path.
      def resolve_baseline_path(configuration, options)
        cli_value = options.fetch(:baseline)
        case cli_value
        when false then nil # --no-baseline
        when :unset then configuration.baseline_path # fall through to config
        else cli_value # --baseline=PATH
        end
      end

      def report_baseline_summary(silenced_count, baseline_path)
        @err.puts("rigor: #{silenced_count} diagnostic(s) silenced by baseline #{baseline_path}")
      end

      # The primary check run, routed through the shared {CheckInvocation} entry point so `rigor doctor` and
      # `rigor skill describe --deep` reach a result through this exact path rather than re-deriving it (#148).
      # Required lazily for the reason the old inline `CheckRunnerFactory.build` was: it pulls the inference engine,
      # and ADR-87 WD4's cache-hit fast path must reach its verdict without it.
      def invoke_check(configuration:, options:, buffer:, cache_root:)
        require_relative "check_invocation"
        CheckInvocation.run(
          configuration: configuration, options: options,
          buffer: buffer, cache_root: cache_root,
          paths: @argv.empty? ? nil : @argv
        )
      end

      def parse_check_options # rubocop:disable Metrics/AbcSize,Metrics/MethodLength
        options = {
          config: nil,
          format: "text",
          explain: false,
          cache_stats: false,
          clear_cache: false,
          no_cache: false,
          stats: true,
          # ADR-15 Phase 4c — when nil, falls back to `RIGOR_RACTOR_WORKERS` then `.rigor.yml` `parallel.workers:` then
          # 0 (sequential). See `resolve_workers` for the precedence chain.
          workers: nil,
          tmp_file: nil,
          instead_of: nil,
          # ADR-22 — baseline filter. `:unset` means "fall through to `.rigor.yml`'s `baseline:` key"; a String
          # overrides the config; `false` (from `--no-baseline`) suppresses any baseline that the config might name.
          baseline: :unset,
          # ADR-22 slice 5 — `--baseline-strict` CI gate: fail the run on any baseline drift, in either direction.
          baseline_strict: false,
          # ADR-32 WD10 carry-over — `--treat-all-as-inline-rbs` forces the `rigor-rbs-inline` plugin into the loaded
          # plugin set with `require_magic_comment: false` so a single ad-hoc `rigor check` invocation treats every
          # analysed file as inline-RBS without the user editing `.rigor.yml`. Intended for single-file / ad-hoc CI use;
          # ordinary projects should configure the plugin in `.rigor.yml`.
          treat_all_as_inline_rbs: false,
          # ADR-46 — the incremental-analysis acceptance gate. Runs a baseline analysis, re-analyzes a subset and serves
          # the rest from the per-file cache, and asserts the merged diagnostics are byte-identical to a full
          # `--no-cache` run. Exits non-zero on any mismatch. Off by default.
          verify_incremental: false,
          # ADR-46 — cross-process incremental analysis. With a disk snapshot of the prior run's per-file diagnostics +
          # dependency graph, re-analyzes only the changed closure and serves the rest from the snapshot. Off by
          # default.
          incremental: false,
          # ADR-51 WD7 — CI auto-detection. When the default `text` format is in effect and a first-class CI is detected
          # (GitHub Actions / TeamCity), also emit that platform's native annotations on top of the human output; for
          # GitLab / reviewdog-routed CIs, print a one-line hint. On by default; `--no-ci-detect` (or
          # `RIGOR_CI_DETECT=0`) disables it.
          ci_detect: true,
          # ADR-50 § WD2 — the `--bleeding-edge[=ids]` / `--no-bleeding-edge` CLI mirror of the `bleeding_edge:` config
          # key. `:unset` means "no flag — use the configured selection"; `true` adopts the whole overlay, `false`
          # adopts none, and an Array of ids adopts only those (see `apply_bleeding_edge_override`).
          bleeding_edge: :unset,
          # ADR-103 WD1 / #385 — the effect-policy audit switch. Judges `effect.envelope-exceeded` as if
          # `effects.tolerated:` were empty, so a project can see what its discharge policy is hiding
          # without editing the policy. Judgment-time only: the run, its collection and its cache identity
          # are identical either way.
          no_tolerated_effects: false,
          # Type-precision coverage block. Off by default — it is a second precision pass over the analyzed files (the
          # same scan `rigor coverage` runs), so it is opt-in to keep the default check path's cost unchanged. When set,
          # `--format json` gains a `coverage` object (scan_files + precision tiers) and the text output prints a
          # one-line coverage summary.
          coverage: false
        }
        parser = OptionParser.new do |opts| # rubocop:disable Metrics/BlockLength
          opts.banner = "Usage: rigor check [options] [paths]"
          Options.add_config(opts, options)
          opts.on("--format=FORMAT",
                  "Output format: text, json, sarif, github, gitlab, checkstyle, junit, teamcity") do |value|
            options[:format] = value
          end
          opts.on("--explain", "Surface fail-soft fallback events as :info diagnostics") { options[:explain] = true }
          opts.on("--cache-stats", "Print on-disk cache inventory at end of run") { options[:cache_stats] = true }
          opts.on("--coverage",
                  "Add a type-precision coverage block (an extra precision pass over the analyzed files)") do
            options[:coverage] = true
          end
          opts.on("--clear-cache", "Remove the .rigor/cache directory before running") { options[:clear_cache] = true }
          opts.on("--no-cache", "Disable the persistent cache for this run") { options[:no_cache] = true }
          opts.on("--[no-]stats",
                  "Print run summary (files, classes, memory, wall time) to stderr (default: on)") do |value|
            options[:stats] = value
          end
          opts.on("--workers=N", Integer,
                  "Dispatch per-file analysis across N Ractor workers (default: 0; sequential)") do |value|
            options[:workers] = value
          end
          Options.add_editor_mode(opts, options)
          opts.on("--baseline=PATH",
                  "ADR-22: load baseline from PATH (overrides .rigor.yml `baseline:`)") do |value|
            options[:baseline] = value
          end
          opts.on("--no-baseline",
                  "ADR-22: ignore any configured baseline for this run") do
            options[:baseline] = false
          end
          opts.on("--baseline-strict",
                  "ADR-22: fail the run on any baseline drift (CI gate)") do
            options[:baseline_strict] = true
          end
          opts.on("--treat-all-as-inline-rbs",
                  "ADR-32: force-load rigor-rbs-inline with require_magic_comment: false") do
            options[:treat_all_as_inline_rbs] = true
          end
          opts.on("--verify-incremental",
                  "ADR-46: assert incremental analysis matches a full run, then exit") do
            options[:verify_incremental] = true
          end
          opts.on("--incremental",
                  "ADR-46: re-analyze only files changed since the last run (cross-process cache)") do
            options[:incremental] = true
          end
          opts.on("--no-ci-detect",
                  "ADR-51: do not auto-emit CI-native output when a CI environment is detected") do
            options[:ci_detect] = false
          end
          # ADR-50 § WD2 — `=[LIST]` (not ` [LIST]`) so a bare `--bleeding-edge` never swallows a following positional
          # path: `rigor check --bleeding-edge lib` adopts the whole overlay and checks `lib`.
          opts.on("--bleeding-edge=[LIST]",
                  "ADR-50: adopt the bleeding-edge overlay for this run " \
                  "(all features, or a comma-separated feature-id list)") do |value|
            options[:bleeding_edge] = value.nil? || value.split(",").map(&:strip).reject(&:empty?)
          end
          opts.on("--no-bleeding-edge",
                  "ADR-50: ignore any configured bleeding_edge: selection for this run") do
            options[:bleeding_edge] = false
          end
          opts.on("--no-tolerated-effects",
                  "ADR-103: check effect envelopes as if effects.tolerated: were empty") do
            options[:no_tolerated_effects] = true
          end
        end
        parser.parse!(@argv)
        options
      end

      # Surfaces the class of mistake where a configured value resolves to nothing — a typo'd or moved
      # `signature_paths:` / bundler / collection path, an unknown `libraries:` name, an inert `disable:` /
      # `severity_overrides:` rule id ({ConfigAudit}). The loader filters each one silently, and the downstream symptom
      # is confusing: missing signatures turn calls into high-confidence `call.undefined-method` firings, and an
      # unrecognised suppression token leaves the rule firing as if the line were never written — so a one-character
      # mistake can read as hundreds of real errors. Each finding is emitted to STDERR (a warning, not a hard error —
      # partial / optional bundles are a valid setup) and the returned list rides into the `--format=json` payload under
      # `config_warnings` so CI and framework consumers can assert on it. The audits only fire on explicit,
      # working-setup-safe signals (see {ConfigAudit}).
      def warn_unresolved_config(configuration)
        warnings = ConfigAudit.warnings(configuration)
        warnings.each { |warning| @err.puts("rigor: #{warning.message}") }
        warnings
      end

      # ADR-32 WD10 carry-over — wraps `Configuration.load` so the CLI's `--treat-all-as-inline-rbs` flag can inject a
      # `rigor-rbs-inline` plugin entry with `require_magic_comment: false` into the loaded plugin set. Re-runs the
      # include-aware YAML load and applies the injection before `Configuration.new` so the new entry follows the normal
      # coercion path. A pre-existing `rigor-rbs-inline` entry (by gem name or `id: rbs-inline`) is removed first so the
      # synthesised entry's `require_magic_comment: false` wins unconditionally.
      def load_check_configuration(options)
        return Configuration.load(options.fetch(:config)) unless options.fetch(:treat_all_as_inline_rbs)

        path = options.fetch(:config) || Configuration.discover
        data = path && File.exist?(path) ? Configuration.load_with_includes(path) : {}
        # ADR-103 WD15 — captured before `DEFAULTS.merge` below folds "no `effects:` key" and "`effects:
        # false`" into the same value; see `Configuration.load`'s identical capture.
        effects_key_present = data.key?("effects")
        data = data.dup
        data["plugins"] = inject_treat_all_as_inline_rbs(Array(data["plugins"]))
        Configuration.new(Configuration::DEFAULTS.merge(data), effects_key_present)
      end

      # ADR-50 § WD2 — applies the `--bleeding-edge[=ids]` / `--no-bleeding-edge` CLI selection over the configured
      # `bleeding_edge:` value, mirroring the CLI-over-config precedence `--workers` and `--no-cache` follow. `:unset`
      # (no flag) leaves the loaded configuration untouched; any other value is normalised by
      # {Configuration#with_bleeding_edge}, so the two `SeverityProfile.resolve` sites (and the worker path, which
      # receives the whole frozen Configuration) see the run's selection.
      def apply_bleeding_edge_override(configuration, options)
        selection = options.fetch(:bleeding_edge)
        return configuration if selection == :unset

        configuration.with_bleeding_edge(selection)
      end

      def inject_treat_all_as_inline_rbs(entries)
        # Single-homed with the WD2 auto-wire gate (`Configuration.rbs_inline_plugin_entry?`) so the flag and
        # the default agree on what "already listed" means; a pre-existing entry is removed so this one's
        # `require_magic_comment: false` wins unconditionally.
        filtered = entries.reject { |entry| Configuration.rbs_inline_plugin_entry?(entry) }
        filtered + [{
          "gem" => "rigor-rbs-inline",
          "id" => "rbs-inline",
          "config" => { "require_magic_comment" => false }
        }]
      end

      def handle_clear_cache(cache_root)
        if File.directory?(cache_root)
          FileUtils.rm_rf(cache_root)
          @out.puts("Cleared cache: #{cache_root}")
        else
          @out.puts("Cache already empty: #{cache_root}")
        end
      end

      # Emits the {Analysis::RunStats} summary to STDERR so it doesn't interleave with the diagnostic stream (text or
      # JSON) on STDOUT. JSON consumers can pipe stdout cleanly; interactive users still see the summary on their tty.
      def write_run_stats(stats)
        @err.puts("")
        stats.format(@err)
      end

      # Opt-in developer diagnostics printed after the run: the inference-cutoff trace (RIGOR_BUDGET_TRACE) and the
      # heap-attribution profile (RIGOR_HEAP_PROFILE). Each gates itself, so this is a no-op on a normal run.
      def write_trace_appendices
        write_budget_trace
        write_heap_profile
      end

      # Dumps the opt-in inference-cutoff counters (RIGOR_BUDGET_TRACE). These are the hard-coded "budget" guards that
      # silently degrade to `Dynamic[top]` / a fallback bound — counting them shows where inference actually stopped.
      # Process-global counters: meaningful only on a single-process run (`--workers 0`), since they do not cross fork
      # boundaries.
      def write_budget_trace
        return unless Inference::BudgetTrace.enabled?

        counts = Inference::BudgetTrace.snapshot
        @err.puts("")
        @err.puts("Inference cutoffs (RIGOR_BUDGET_TRACE; --workers 0 for an exact count)")
        @err.puts("  recursion-guard hits:      #{counts[Inference::BudgetTrace::RECURSION_GUARD]}")
        @err.puts("  ancestor-walk-limit hits:  #{counts[Inference::BudgetTrace::ANCESTOR_WALK_LIMIT]}")
        @err.puts("  hkt-fuel-exhausted hits:   #{counts[Inference::BudgetTrace::HKT_FUEL_EXHAUSTED]}")
        @err.puts("  recursion-unroll-fuel hits: #{counts[Inference::BudgetTrace::RECURSION_UNROLL_FUEL]}")
        @err.puts("  recursion-fixpoint-cap hits: #{counts[Inference::BudgetTrace::RECURSION_FIXPOINT_CAP]}")
        @err.puts("  block-writeback-cap hits:  #{counts[Inference::BudgetTrace::BLOCK_WRITEBACK_CAP]}")
        write_budget_distributions
        write_memo_profile(counts)
      end

      # Dumps the ADR-57 return-memo profile (WD0). Entries / hit rate / body evals / the non-store split, then
      # the top signatures by body-eval count with their distinct-memo-key counts — the evidence for choosing
      # between a finalization-aware taint gate and memo-key normalization. `--workers 0` for exact counts.
      def write_memo_profile(counts)
        bt = Inference::BudgetTrace
        hits = counts[bt::MEMO_HITS]
        misses = counts[bt::MEMO_MISSES]
        consults = hits + misses
        rate = consults.positive? ? format("%.1f%%", 100.0 * hits / consults) : "n/a"
        @err.puts("")
        @err.puts("Return-memo profile (RIGOR_BUDGET_TRACE; --workers 0 for an exact count)")
        @err.puts("  infer entries:   #{counts[bt::MEMO_ENTRIES]}")
        @err.puts("  memo consults:   #{consults}  (hits #{hits} / misses #{misses}; hit rate #{rate})")
        @err.puts("  body evals:      #{counts[bt::MEMO_BODY_EVALS]}")
        @err.puts("  non-stored:      on-stack #{counts[bt::MEMO_REFUSE_ON_STACK]}  " \
                  "unroll-in-flight #{counts[bt::MEMO_REFUSE_UNROLL]}  " \
                  "consult-tainted #{counts[bt::MEMO_REFUSE_CONSULT_TAINTED]}  " \
                  "transient-tainted #{counts[bt::MEMO_REFUSE_TRANSIENT]}")
        write_memo_signature_table
      end

      # Top 15 signatures by body-eval (compute) count, each with its distinct-memo-key count — a signature
      # whose distinct-key count dwarfs its evals is arg-granularity thrash (the key-normalization candidate).
      def write_memo_signature_table
        bt = Inference::BudgetTrace
        evals = bt.distribution(bt::MEMO_BODY_EVAL_BY_SIGNATURE)
        return if evals.empty?

        keys = bt.distribution(bt::MEMO_DISTINCT_KEY_BY_SIGNATURE)
        @err.puts("  top signatures by body-eval count (evals / distinct-keys / signature):")
        evals.sort_by { |sig, n| [-n, sig] }.first(15).each do |sig, n|
          @err.puts("    #{n.to_s.rjust(8)}  #{keys.fetch(sig, 0).to_s.rjust(6)}  #{sig}")
        end
      end

      # Dumps the read-only size distributions (ADR-41 Slice 2a). These observe how large unions actually get, with no
      # cap enforced — the data the `union_size` budget default should be chosen from. The `over` thresholds bracket the
      # TypeProf prior (10) and Rigor's spec default (24).
      def write_budget_distributions
        summary = Inference::BudgetTrace.summarize(Inference::BudgetTrace::UNION_ARITY, over: [10, 24, 40])
        pct = summary[:percentiles]
        @err.puts("  union arity:  n=#{summary[:count]} max=#{summary[:max]} " \
                  "p50=#{pct[:p50]} p90=#{pct[:p90]} p99=#{pct[:p99]}")
        over = summary[:over]
        @err.puts("    unions ≥10: #{over[10]}  ≥24: #{over[24]}  ≥40: #{over[40]}")
      end

      # Dumps a live-heap class breakdown (RIGOR_HEAP_PROFILE) — retained objects by class after a forced GC, ranked by
      # total memsize. The tool for attributing where the analyzer's resident memory goes (ADR-41 Slice 2b): it answers
      # whether the heap is type carriers, RBS objects, Prism nodes, or fact-store Hashes/Strings. Walking the whole
      # heap is slow — a dev probe, not a normal diagnostic. Run single-process (`--workers 0`) so the parent heap is
      # the analysis heap; the gem is required lazily so a normal run never loads it.
      def write_heap_profile
        return if ENV["RIGOR_HEAP_PROFILE"].to_s.empty?

        by_class, total = tally_live_heap
        @err.puts("")
        @err.puts("Heap profile (RIGOR_HEAP_PROFILE; live objects after GC, by class)")
        @err.puts("  total tracked: #{heap_mb(total)} across #{by_class.size} classes")
        by_class.sort_by { |_, (_, bytes)| -bytes }.first(30).each do |name, (count, bytes)|
          @err.puts("  #{heap_mb(bytes).rjust(10)}  #{count.to_s.rjust(9)} obj  #{name}")
        end
        write_string_allocation_sites
      end

      # Loads the analysis-path dependencies lazily (so non-check commands stay light) and starts heap-allocation
      # tracing if requested, before any analysis object is allocated.
      def load_check_dependencies
        require_relative "../analysis/runner"
        require_relative "../analysis/buffer_binding"
        require_relative "../cache/store"
        start_heap_trace_if_requested
      end

      # Starts allocation tracing (RIGOR_HEAP_TRACE) as early as possible so the heap profile can attribute retained
      # Strings to their allocation `file:line`. Very high overhead — run on a small file subset only.
      def start_heap_trace_if_requested
        return if ENV["RIGOR_HEAP_TRACE"].to_s.empty?

        require "objspace"
        ObjectSpace.trace_object_allocations_start
      end

      # When RIGOR_HEAP_TRACE is on, groups the live String objects by their allocation site (`sourcefile:sourceline`)
      # and prints the top sites by count — pinpointing which engine code retains the millions of strings that dominate
      # the large-app heap (ADR-41 Slice 2b). Strings allocated before tracing started report `(pre-trace)`.
      def write_string_allocation_sites
        return if ENV["RIGOR_HEAP_TRACE"].to_s.empty?

        by_site = Hash.new(0)
        ObjectSpace.each_object(String) do |str|
          file = ObjectSpace.allocation_sourcefile(str)
          line = ObjectSpace.allocation_sourceline(str)
          by_site[file ? "#{file}:#{line}" : "(pre-trace)"] += 1
        end
        @err.puts("")
        @err.puts("  String allocation sites (top 25 by live count)")
        by_site.sort_by { |_, n| -n }.first(25).each do |site, n|
          @err.puts("  #{n.to_s.rjust(9)}  #{site}")
        end
      end

      # Walks the whole live heap (after a forced GC) and tallies `{class_name => [count, memsize]}` plus the grand
      # total. Returns `[by_class, total]`. Slow — a dev probe only.
      def tally_live_heap
        require "objspace"
        GC.start
        by_class = Hash.new { |h, k| h[k] = [0, 0] }
        total = 0
        ObjectSpace.each_object do |obj|
          size = ObjectSpace.memsize_of(obj)
          entry = by_class[heap_class_name(obj)]
          entry[0] += 1
          entry[1] += size
          total += size
        end
        [by_class, total]
      end

      def heap_class_name(obj)
        klass = Object.instance_method(:class).bind_call(obj)
        klass.name || klass.inspect
      rescue StandardError
        "(unknown)"
      end

      def heap_mb(bytes)
        Kernel.format("%.1f MB", bytes / 1_048_576.0)
      end

      def write_cache_stats(cache_root, runtime_store)
        inv = Cache::Store.disk_inventory(root: cache_root)

        @out.puts("")
        @out.puts("Cache (root: #{inv.fetch(:root)})")
        schema = inv.fetch(:schema_version)
        @out.puts("  schema_version: #{schema.nil? ? 'absent' : schema}")
        write_disk_inventory(inv)
        write_runtime_stats(runtime_store) if runtime_store
      end

      def write_disk_inventory(inv)
        if inv.fetch(:total_entries).zero?
          @out.puts("  (empty)")
          return
        end

        @out.puts("  #{inv.fetch(:total_entries)} entries, #{format_bytes(inv.fetch(:total_bytes))}")
        inv.fetch(:producers).each do |producer|
          bytes = format_bytes(producer.fetch(:bytes))
          @out.puts("    #{producer.fetch(:id)}: #{producer.fetch(:entries)} entries, #{bytes}")
        end
      end

      def write_runtime_stats(store)
        stats = store.stats
        hits = stats.fetch(:hits)
        misses = stats.fetch(:misses)
        writes = stats.fetch(:writes)
        @out.puts("  this run: #{hits} #{plural(hits, 'hit')}, " \
                  "#{misses} #{plural(misses, 'miss', 'misses')}, " \
                  "#{writes} #{plural(writes, 'write')}")
        stats.fetch(:by_producer).each do |id, counts|
          @out.puts("    #{id}: #{counts.fetch(:hits)} #{plural(counts.fetch(:hits), 'hit')}, " \
                    "#{counts.fetch(:misses)} #{plural(counts.fetch(:misses), 'miss', 'misses')}, " \
                    "#{counts.fetch(:writes)} #{plural(counts.fetch(:writes), 'write')}")
        end
      end

      def plural(count, singular, plural = "#{singular}s")
        count == 1 ? singular : plural
      end

      def format_bytes(bytes)
        return "#{bytes} B" if bytes < 1024
        return format("%.1f KiB", bytes / 1024.0) if bytes < 1024 * 1024

        format("%.1f MiB", bytes / (1024.0 * 1024.0))
      end

      def write_result(result, format, coverage: nil, config_warnings: [])
        case format
        when "json"
          payload = enrich_json(result.to_h)
          payload["coverage"] = coverage_payload(coverage) if coverage
          payload["config_warnings"] = config_warnings.map(&:to_h) unless config_warnings.empty?
          @out.puts(JSON.pretty_generate(payload))
        when "text"
          write_text_result(result)
          write_coverage_summary(coverage) if coverage
        when ->(fmt) { CLI::DiagnosticFormats.supports?(fmt) }
          # ADR-51 — CI-native renderings (SARIF / GitHub Actions commands / GitLab Code Quality). The `github` form is
          # empty when there are no diagnostics; the JSON forms always carry a document.
          output = CLI::DiagnosticFormats.render(result, format)
          @out.puts(output) unless output.empty?
        else
          raise OptionParser::InvalidArgument, "unsupported format: #{format}"
        end
      end

      # Runs the type-precision scan (`--coverage`) over the same file set the check analyzed and returns a
      # `CoverageReport`, or nil when the flag is off. It is a second pass — the same scan `rigor coverage` runs, reused
      # via {CoverageScan} — so it is opt-in to keep the default check path's cost unchanged.
      def compute_coverage(runner, configuration, options)
        return nil unless options.fetch(:coverage)

        require_relative "coverage_scan"
        files = @argv.empty? ? runner.analysis_file_set : runner.analysis_file_set(@argv)
        CoverageScan.precision_report(files: files, configuration: configuration)
      end

      # The `coverage` block embedded in `--format json`. Mirrors the `summary` of `rigor coverage --format json` (the
      # same vocabulary — `precise_ratio`, not a separate `typed_ratio`) plus `scan_files`, so a consumer reads one
      # stream to learn both what fired and how much of the analyzed surface Rigor could type.
      def coverage_payload(report)
        {
          "scan_files" => report.files.size - report.parse_errors.size,
          "parse_errors" => report.parse_errors.size,
          "expressions_typed" => report.grand_total,
          "precise_count" => report.precise_count,
          "precise_ratio" => report.precision_ratio.round(4),
          "dynamic_opaque_count" => report.opaque_count,
          "dynamic_opaque_ratio" => report.opaque_ratio.round(4)
        }
      end

      def write_coverage_summary(report)
        files = report.files.size - report.parse_errors.size
        pct = (report.precision_ratio * 100).round(1)
        @out.puts("Type coverage: #{files} file(s), #{pct}% precise " \
                  "(#{report.precise_count}/#{report.grand_total} expressions). " \
                  "Run `rigor coverage` for the full per-file / per-tier breakdown.")
      end

      # Adds the per-rule `evidence_tier` and `documentation_url` fields to each diagnostic in the `--format json`
      # payload. Both are pure functions of the rule id (the rule catalogue, ADR-61 / the 2026-06-15 feedback §4 +
      # §5.1), so they enrich the presentation layer here rather than threading through every diagnostic construction
      # site. Only built-in rules carry catalogue metadata; plugin / `rbs_extended` / parse-error diagnostics are left
      # untouched (they host their own documentation and confidence).
      def enrich_json(payload)
        Array(payload["diagnostics"]).each do |diag|
          next unless diag["source_family"] == Analysis::Diagnostic::DEFAULT_SOURCE_FAMILY.to_s

          rule = diag["rule"]
          next unless rule

          tier = Analysis::RuleCatalog.evidence_tier(rule)
          diag["evidence_tier"] = tier.to_s if tier
          url = Analysis::RuleCatalog.documentation_url(rule)
          diag["documentation_url"] = url if url
        end
        payload
      end

      # ADR-51 WD7 — CI auto-detection. Only augments the default human (`text`) output: an explicit `--format` means
      # the caller is in control and is left untouched. For a first-class stdout-native CI (GitHub Actions / TeamCity)
      # the platform's annotations are emitted on top of the text output (so the human log AND the inline surface both
      # appear, like PHPStan's CI-detecting table formatter). For GitLab (native but artifact-based) and the
      # reviewdog-routed CIs, a one-line hint goes to stderr — but only when there are diagnostics, so a clean run stays
      # quiet.
      def emit_ci_detected_output(result, options)
        return unless options.fetch(:ci_detect)
        return unless options.fetch(:format) == "text"

        platform = CiDetector.detect
        return if platform.nil?

        if platform.native_stdout?
          output = CLI::DiagnosticFormats.render(result, platform.format)
          @out.puts(output) unless output.empty?
        elsif !result.success? || result.diagnostics.any?
          @err.puts(ci_detected_hint(platform))
        end
      end

      def ci_detected_hint(platform)
        tail = "see `rigor skill rigor-ci-setup`"
        if platform.native_artifact?
          "rigor: #{platform.name} detected — for the inline report run " \
            "`rigor check --format #{platform.format}` and publish it as the platform's report artifact (#{tail})."
        else
          "rigor: #{platform.name} detected — Rigor has no native format for it; pipe " \
            "`rigor check --format checkstyle` through reviewdog, or use `--format junit` (#{tail})."
        end
      end

      # Text output adds a one-line summary so users see the diagnostic-count immediately. The summary distinguishes the
      # success and failure cases and reports the affected file count for failures.
      def write_text_result(result)
        result.diagnostics.each { |diagnostic| @out.puts(diagnostic) }

        if result.success?
          @out.puts("No diagnostics") if result.diagnostics.empty?
          return
        end

        error_files = result.diagnostics.select(&:error?).map(&:path).uniq.size
        @out.puts("")
        @out.puts("#{result.error_count} error(s) in #{error_files} file(s)")
      end
    end
  end
end
