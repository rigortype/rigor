# frozen_string_literal: true

require "fileutils"
require "json"
require "optionparser"

require_relative "../configuration"
require_relative "../analysis/result"
require_relative "command"
require_relative "options"
require_relative "diagnostic_formats"
require_relative "ci_detector"

module Rigor
  class CLI
    # Executes `rigor check` — the analyzer's primary command.
    #
    # The other subcommands delegate to a `CLI::Command` subclass once they
    # grow beyond a few lines; `check` is the largest of them, owning option
    # parsing, the baseline filter (ADR-22), the incremental modes (ADR-46),
    # cache-stats reporting, editor mode, the CI-native output formats
    # (ADR-51), and the diagnostic-only / heap / budget appendices. Keeping
    # it in its own class follows the same dispatch-vs-implementation split
    # the rest of the CLI uses and keeps `Rigor::CLI` focused on dispatch.
    #
    # The class-length budget is relaxed (as on `Rigor::CLI` itself) because
    # `check` aggregates several independent concerns that are clearer read
    # together than split across micro-classes.
    class CheckCommand < Command # rubocop:disable Metrics/ClassLength
      # @return [Integer] CLI exit status.
      def run # rubocop:disable Metrics/AbcSize
        load_check_dependencies
        options = parse_check_options
        buffer = Options.resolve_buffer_binding(options, err: @err)
        return CLI::EXIT_USAGE if buffer == :usage_error

        configuration = load_check_configuration(options)
        cache_root = configuration.cache_path
        handle_clear_cache(cache_root) if options.fetch(:clear_cache)

        special = dispatch_special_check_mode(configuration, options, cache_root)
        return special unless special.nil?

        runner = build_check_runner(
          configuration: configuration, options: options,
          buffer: buffer, cache_root: cache_root
        )
        raw_result = runner.run(@argv.empty? ? configuration.paths : @argv)
        result = apply_baseline_filter(raw_result, configuration, options)

        write_result(result, options.fetch(:format))
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

      # ADR-46 — the two incremental-analysis check modes both fully handle
      # the run and return an exit code (so `run` short-circuits);
      # returns nil for an ordinary check.
      def dispatch_special_check_mode(configuration, options, cache_root)
        return run_verify_incremental(configuration) if options.fetch(:verify_incremental)
        return run_incremental_check(configuration, options, cache_root) if options.fetch(:incremental)

        nil
      end

      # ADR-46 — the incremental-analysis acceptance gate. Runs a baseline
      # analysis (recording cross-file dependencies), then re-analyzes a
      # representative subset of files and serves the rest from the per-file
      # cache (the body tier), and asserts the merged diagnostics are
      # byte-identical to a full `--no-cache` analysis. A mismatch means the
      # incremental machinery would serve a stale — manufactured —
      # diagnostic, the soundness failure this gate exists to catch. Prints a
      # one-line PASS (exit 0) or the differing diagnostics (exit 1).
      def run_verify_incremental(configuration)
        paths = @argv.empty? ? nil : @argv
        session = Analysis::IncrementalSession.new(configuration: configuration, paths: paths)
        session.baseline
        analyzed = session.analyzed_files

        # Every other file forms the re-analyzed subset, so the run exercises
        # BOTH the subset-analysis path and the cache-serving path.
        subset = analyzed.each_with_index.select { |_, index| index.even? }.map(&:first)
        incremental = normalize_diagnostics(session.reanalyze_subset(subset))
        full = normalize_diagnostics(verify_full_diagnostics(configuration, paths))

        report_verify_incremental(incremental, full, subset_size: subset.size, total: analyzed.size)
      end

      # ADR-46 — cross-process incremental analysis (`--incremental`). Derives
      # the global fingerprint cheaply (no RBS env build), loads the disk
      # snapshot, and on a fingerprint hit re-analyzes only the files changed
      # since the last run (plus their dependents), serving the rest from the
      # snapshot; on a miss runs a full baseline. Persists the updated
      # snapshot for the next invocation. Diagnostics are identical to a full
      # run (the `--verify-incremental` gate enforces this); the win is
      # skipping per-file inference for unchanged files.
      def run_incremental_check(configuration, options, cache_root)
        paths = @argv.empty? ? nil : @argv
        probe = Analysis::Runner.new(configuration: configuration, cache_store: nil)
        files = paths ? probe.analysis_file_set(paths) : probe.analysis_file_set
        fingerprint = Cache::IncrementalSnapshot.fingerprint(
          configuration: configuration, roots: paths || configuration.paths
        )
        snapshot = Cache::IncrementalSnapshot.new(root: cache_root)
        session = Analysis::IncrementalSession.new(configuration: configuration, paths: paths)

        diagnostics, warm = session.run_incremental(snapshot: snapshot, fingerprint: fingerprint)
        @err.puts("rigor: --incremental #{warm ? 'warm — reused cached diagnostics' : 'cold — full analysis'} " \
                  "(#{files.size} files)")

        result = apply_baseline_filter(Analysis::Result.new(diagnostics: diagnostics, stats: nil), configuration,
                                       options)
        write_result(result, options.fetch(:format))
        result.success? ? 0 : 1
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

      # ADR-22 slice 5 — the `--baseline-strict` CI gate. When the
      # flag is set, ANY baseline drift fails the run — not only
      # excess drift (a bucket over threshold, which already fails
      # via the surfaced diagnostics) but also DEFICIT drift
      # (`actual < count`: the baseline has grown looser than the
      # code and should be regenerated). A no-op, with a stderr
      # note, when no baseline is active — the flag never
      # implicitly loads a baseline the config did not name (WD2).
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

      # ADR-22 — apply the baseline filter as the LAST step of
      # the diagnostic pipeline (after `# rigor:disable`,
      # `severity_profile`, etc. — WD6). Resolution order
      # follows WD2 (b):
      #
      #   1. --no-baseline on the CLI → no baseline.
      #   2. --baseline=PATH on the CLI → load that path.
      #   3. .rigor.yml's `baseline: <path>` → load that path.
      #   4. otherwise → no baseline.
      #
      # When the path resolves and loads successfully, the filter
      # replaces `result.diagnostics` with the surfaced set and
      # writes a one-line summary to stderr (WD7) when any
      # diagnostics were silenced. Load failures emit a warning
      # to stderr and fall through to "no baseline" (graceful
      # degradation).
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

      def build_check_runner(configuration:, options:, buffer:, cache_root:)
        cache_store = if options.fetch(:no_cache)
                        nil
                      else
                        Cache::Store.new(
                          root: cache_root,
                          max_bytes: configuration.cache_max_bytes
                        )
                      end
        Analysis::Runner.new(
          configuration: configuration,
          explain: options.fetch(:explain),
          cache_store: cache_store,
          collect_stats: options.fetch(:stats),
          workers: resolve_workers(options, configuration),
          buffer: buffer
        )
      end

      # ADR-15 Phase 4c — resolves the worker count by
      # precedence: CLI `--workers=N` (most explicit) > env
      # `RIGOR_RACTOR_WORKERS` > config `.rigor.yml`
      # `parallel.workers:` > 0 (sequential default). Returns
      # an Integer; non-numeric values raise so typos fail
      # loudly. CLI / env may pass a negative value — clamped
      # to 0 (sequential) so a stray `-1` doesn't crash the
      # pool spawn loop.
      def resolve_workers(options, configuration)
        cli_value = options[:workers]
        return [Integer(cli_value), 0].max if cli_value

        env_value = ENV.fetch("RIGOR_RACTOR_WORKERS", nil)
        return [Integer(env_value), 0].max if env_value && !env_value.empty?

        configuration.parallel_workers
      end

      def parse_check_options # rubocop:disable Metrics/AbcSize,Metrics/MethodLength
        options = {
          # `nil` triggers `Configuration.discover` (`.rigor.yml` then
          # `.rigor.dist.yml`); an explicit `--config=PATH` overrides.
          config: nil,
          format: "text",
          explain: false,
          cache_stats: false,
          clear_cache: false,
          no_cache: false,
          # Run-stats summary (target files, RBS class universe
          # breakdown, wall time, peak RSS) is on by default
          # because collection is ~free (single syscall for RSS,
          # one walk of `class_decl_paths` for the breakdown).
          # `--no-stats` suppresses it for callers that want a
          # diagnostic-only output stream.
          stats: true,
          # ADR-15 Phase 4c — when nil, falls back to
          # `RIGOR_RACTOR_WORKERS` then `.rigor.yml`
          # `parallel.workers:` then 0 (sequential). See
          # `resolve_workers` for the precedence chain.
          workers: nil,
          # Editor mode (`docs/design/20260516-editor-mode.md`).
          # Both must appear together; the runner uses the pair
          # to bind an in-flight buffer file to its logical path.
          tmp_file: nil,
          instead_of: nil,
          # ADR-22 — baseline filter. `:unset` means "fall through
          # to `.rigor.yml`'s `baseline:` key"; a String overrides
          # the config; `false` (from `--no-baseline`) suppresses
          # any baseline that the config might name.
          baseline: :unset,
          # ADR-22 slice 5 — `--baseline-strict` CI gate: fail the
          # run on any baseline drift, in either direction.
          baseline_strict: false,
          # ADR-32 WD10 carry-over — `--treat-all-as-inline-rbs`
          # forces the `rigor-rbs-inline` plugin into the loaded
          # plugin set with `require_magic_comment: false` so a
          # single ad-hoc `rigor check` invocation treats every
          # analysed file as inline-RBS without the user editing
          # `.rigor.yml`. Intended for single-file / ad-hoc CI use;
          # ordinary projects should configure the plugin in
          # `.rigor.yml`.
          treat_all_as_inline_rbs: false,
          # ADR-46 — the incremental-analysis acceptance gate. Runs a
          # baseline analysis, re-analyzes a subset and serves the rest from
          # the per-file cache, and asserts the merged diagnostics are
          # byte-identical to a full `--no-cache` run. Exits non-zero on any
          # mismatch. Off by default.
          verify_incremental: false,
          # ADR-46 — cross-process incremental analysis. With a disk snapshot
          # of the prior run's per-file diagnostics + dependency graph,
          # re-analyzes only the changed closure and serves the rest from the
          # snapshot. Off by default.
          incremental: false,
          # ADR-51 WD7 — CI auto-detection. When the default `text` format is
          # in effect and a first-class CI is detected (GitHub Actions /
          # TeamCity), also emit that platform's native annotations on top of
          # the human output; for GitLab / reviewdog-routed CIs, print a
          # one-line hint. On by default; `--no-ci-detect` (or
          # `RIGOR_CI_DETECT=0`) disables it.
          ci_detect: true
        }
        parser = OptionParser.new do |opts| # rubocop:disable Metrics/BlockLength
          opts.banner = "Usage: rigor check [options] [paths]"
          opts.on("--config=PATH", "Path to the Rigor configuration file") { |value| options[:config] = value }
          opts.on("--format=FORMAT",
                  "Output format: text, json, sarif, github, gitlab, checkstyle, junit, teamcity") do |value|
            options[:format] = value
          end
          opts.on("--explain", "Surface fail-soft fallback events as :info diagnostics") { options[:explain] = true }
          opts.on("--cache-stats", "Print on-disk cache inventory at end of run") { options[:cache_stats] = true }
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
        end
        parser.parse!(@argv)
        options
      end

      # ADR-32 WD10 carry-over — wraps `Configuration.load` so the
      # CLI's `--treat-all-as-inline-rbs` flag can inject a
      # `rigor-rbs-inline` plugin entry with
      # `require_magic_comment: false` into the loaded plugin
      # set. Re-runs the include-aware YAML load and applies the
      # injection before `Configuration.new` so the new entry
      # follows the normal coercion path. A pre-existing
      # `rigor-rbs-inline` entry (by gem name or `id: rbs-inline`)
      # is removed first so the synthesised entry's
      # `require_magic_comment: false` wins unconditionally.
      def load_check_configuration(options)
        return Configuration.load(options.fetch(:config)) unless options.fetch(:treat_all_as_inline_rbs)

        path = options.fetch(:config) || Configuration.discover
        data = path && File.exist?(path) ? Configuration.load_with_includes(path) : {}
        data = data.dup
        data["plugins"] = inject_treat_all_as_inline_rbs(Array(data["plugins"]))
        Configuration.new(Configuration::DEFAULTS.merge(data))
      end

      def inject_treat_all_as_inline_rbs(entries)
        filtered = entries.reject { |entry| rigor_rbs_inline_entry?(entry) }
        filtered + [{
          "gem" => "rigor-rbs-inline",
          "id" => "rbs-inline",
          "config" => { "require_magic_comment" => false }
        }]
      end

      def rigor_rbs_inline_entry?(entry)
        case entry
        when String
          entry == "rigor-rbs-inline"
        when Hash
          string_keyed = entry.to_h { |k, v| [k.to_s, v] }
          string_keyed["gem"] == "rigor-rbs-inline" || string_keyed["id"] == "rbs-inline"
        else
          false
        end
      end

      def handle_clear_cache(cache_root)
        if File.directory?(cache_root)
          FileUtils.rm_rf(cache_root)
          @out.puts("Cleared cache: #{cache_root}")
        else
          @out.puts("Cache already empty: #{cache_root}")
        end
      end

      # Emits the {Analysis::RunStats} summary to STDERR so it
      # doesn't interleave with the diagnostic stream (text or
      # JSON) on STDOUT. JSON consumers can pipe stdout cleanly;
      # interactive users still see the summary on their tty.
      def write_run_stats(stats)
        @err.puts("")
        stats.format(@err)
      end

      # Opt-in developer diagnostics printed after the run: the
      # inference-cutoff trace (RIGOR_BUDGET_TRACE) and the heap-attribution
      # profile (RIGOR_HEAP_PROFILE). Each gates itself, so this is a no-op
      # on a normal run.
      def write_trace_appendices
        write_budget_trace
        write_heap_profile
      end

      # Dumps the opt-in inference-cutoff counters (RIGOR_BUDGET_TRACE).
      # These are the hard-coded "budget" guards that silently degrade
      # to `Dynamic[top]` / a fallback bound — counting them shows where
      # inference actually stopped. Process-global counters: meaningful
      # only on a single-process run (`--workers 0`), since they do not
      # cross fork boundaries.
      def write_budget_trace
        return unless Inference::BudgetTrace.enabled?

        counts = Inference::BudgetTrace.snapshot
        @err.puts("")
        @err.puts("Inference cutoffs (RIGOR_BUDGET_TRACE; --workers 0 for an exact count)")
        @err.puts("  recursion-guard hits:      #{counts[Inference::BudgetTrace::RECURSION_GUARD]}")
        @err.puts("  ancestor-walk-limit hits:  #{counts[Inference::BudgetTrace::ANCESTOR_WALK_LIMIT]}")
        @err.puts("  hkt-fuel-exhausted hits:   #{counts[Inference::BudgetTrace::HKT_FUEL_EXHAUSTED]}")
        write_budget_distributions
      end

      # Dumps the read-only size distributions (ADR-41 Slice 2a). These
      # observe how large unions actually get, with no cap enforced — the
      # data the `union_size` budget default should be chosen from. The
      # `over` thresholds bracket the TypeProf prior (10) and Rigor's spec
      # default (24).
      def write_budget_distributions
        summary = Inference::BudgetTrace.summarize(Inference::BudgetTrace::UNION_ARITY, over: [10, 24, 40])
        pct = summary[:percentiles]
        @err.puts("  union arity:  n=#{summary[:count]} max=#{summary[:max]} " \
                  "p50=#{pct[:p50]} p90=#{pct[:p90]} p99=#{pct[:p99]}")
        over = summary[:over]
        @err.puts("    unions ≥10: #{over[10]}  ≥24: #{over[24]}  ≥40: #{over[40]}")
      end

      # Dumps a live-heap class breakdown (RIGOR_HEAP_PROFILE) — retained
      # objects by class after a forced GC, ranked by total memsize. The
      # tool for attributing where the analyzer's resident memory goes
      # (ADR-41 Slice 2b): it answers whether the heap is type carriers,
      # RBS objects, Prism nodes, or fact-store Hashes/Strings. Walking the
      # whole heap is slow — a dev probe, not a normal diagnostic. Run
      # single-process (`--workers 0`) so the parent heap is the analysis
      # heap; the gem is required lazily so a normal run never loads it.
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

      # Loads the analysis-path dependencies lazily (so non-check commands
      # stay light) and starts heap-allocation tracing if requested, before
      # any analysis object is allocated.
      def load_check_dependencies
        require_relative "../analysis/runner"
        require_relative "../analysis/buffer_binding"
        require_relative "../analysis/baseline"
        require_relative "../cache/store"
        start_heap_trace_if_requested
      end

      # Starts allocation tracing (RIGOR_HEAP_TRACE) as early as possible so
      # the heap profile can attribute retained Strings to their allocation
      # `file:line`. Very high overhead — run on a small file subset only.
      def start_heap_trace_if_requested
        return if ENV["RIGOR_HEAP_TRACE"].to_s.empty?

        require "objspace"
        ObjectSpace.trace_object_allocations_start
      end

      # When RIGOR_HEAP_TRACE is on, groups the live String objects by their
      # allocation site (`sourcefile:sourceline`) and prints the top sites by
      # count — pinpointing which engine code retains the millions of strings
      # that dominate the large-app heap (ADR-41 Slice 2b). Strings allocated
      # before tracing started report `(pre-trace)`.
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

      # Walks the whole live heap (after a forced GC) and tallies
      # `{class_name => [count, memsize]}` plus the grand total. Returns
      # `[by_class, total]`. Slow — a dev probe only.
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

      def write_result(result, format)
        case format
        when "json"
          @out.puts(JSON.pretty_generate(result.to_h))
        when "text"
          write_text_result(result)
        when ->(fmt) { CLI::DiagnosticFormats.supports?(fmt) }
          # ADR-51 — CI-native renderings (SARIF / GitHub Actions commands /
          # GitLab Code Quality). The `github` form is empty when there are no
          # diagnostics; the JSON forms always carry a document.
          output = CLI::DiagnosticFormats.render(result, format)
          @out.puts(output) unless output.empty?
        else
          raise OptionParser::InvalidArgument, "unsupported format: #{format}"
        end
      end

      # ADR-51 WD7 — CI auto-detection. Only augments the default human
      # (`text`) output: an explicit `--format` means the caller is in control
      # and is left untouched. For a first-class stdout-native CI (GitHub
      # Actions / TeamCity) the platform's annotations are emitted on top of
      # the text output (so the human log AND the inline surface both appear,
      # like PHPStan's CI-detecting table formatter). For GitLab (native but
      # artifact-based) and the reviewdog-routed CIs, a one-line hint goes to
      # stderr — but only when there are diagnostics, so a clean run stays
      # quiet.
      def emit_ci_detected_output(result, options)
        return unless options.fetch(:ci_detect)
        return unless options.fetch(:format) == "text"

        platform = CLI::CiDetector.detect
        return if platform.nil?

        if platform.native_stdout?
          output = CLI::DiagnosticFormats.render(result, platform.format)
          @out.puts(output) unless output.empty?
        elsif !result.success? || result.diagnostics.any?
          @err.puts(ci_detected_hint(platform))
        end
      end

      def ci_detected_hint(platform)
        tail = "see `rigor skill print rigor-ci-setup`"
        if platform.native_artifact?
          "rigor: #{platform.name} detected — for the inline report run " \
            "`rigor check --format #{platform.format}` and publish it as the platform's report artifact (#{tail})."
        else
          "rigor: #{platform.name} detected — Rigor has no native format for it; pipe " \
            "`rigor check --format checkstyle` through reviewdog, or use `--format junit` (#{tail})."
        end
      end

      # Text output adds a one-line summary so users see the
      # diagnostic-count immediately. The summary distinguishes
      # the success and failure cases and reports the affected
      # file count for failures.
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
