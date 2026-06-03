# frozen_string_literal: true

require "fileutils"
require "json"
require "optionparser"
require "yaml"

require_relative "configuration"
require_relative "version"
require_relative "analysis/diagnostic"
require_relative "analysis/result"
require_relative "cli/options"

module Rigor
  # The CLI class is a dispatcher: each `run_*` method delegates to a
  # command-specific class once the command grows beyond a few lines (see
  # {CLI::TypeOfCommand}). The class-length budget is intentionally relaxed
  # here so dispatch wiring can live alongside still-inlined commands.
  class CLI # rubocop:disable Metrics/ClassLength
    EXIT_USAGE = 64

    HANDLERS = {
      "check" => :run_check,
      "init" => :run_init,
      "annotate" => :run_annotate,
      "type-of" => :run_type_of,
      "type-scan" => :run_type_scan,
      "explain" => :run_explain,
      "diff" => :run_diff,
      "sig-gen" => :run_sig_gen,
      "lsp" => :run_lsp,
      "mcp" => :run_mcp,
      "baseline" => :run_baseline,
      "triage" => :run_triage,
      "coverage" => :run_coverage,
      "plugins" => :run_plugins,
      "plugin" => :run_plugin,
      "playground" => :run_playground,
      "skill" => :run_skill
    }.freeze

    def self.start(argv = ARGV, out: $stdout, err: $stderr)
      new(argv.dup, out: out, err: err).run
    end

    def initialize(argv = ARGV.dup, out: $stdout, err: $stderr)
      @argv = argv
      @out = out
      @err = err
    end

    def run
      command = @argv.shift

      case command
      when nil, "help", "-h", "--help"
        @out.puts(help)
        0
      when "version", "-v", "--version"
        @out.puts("rigor #{Rigor::VERSION}")
        0
      else
        dispatch(command)
      end
    rescue OptionParser::ParseError => e
      @err.puts(e.message)
      EXIT_USAGE
    end

    private

    def dispatch(command)
      handler = HANDLERS[command]
      return send(handler) if handler

      @err.puts("Unknown command: #{command}")
      @err.puts(help)
      EXIT_USAGE
    end

    def run_check
      load_check_dependencies
      options = parse_check_options
      buffer = Options.resolve_buffer_binding(options, err: @err)
      return EXIT_USAGE if buffer == :usage_error

      configuration = load_check_configuration(options)
      cache_root = configuration.cache_path
      handle_clear_cache(cache_root) if options.fetch(:clear_cache)

      runner = build_check_runner(
        configuration: configuration, options: options,
        buffer: buffer, cache_root: cache_root
      )
      raw_result = runner.run(@argv.empty? ? configuration.paths : @argv)
      result = apply_baseline_filter(raw_result, configuration, options)

      write_result(result, options.fetch(:format))
      write_run_stats(result.stats) if result.stats
      write_trace_appendices
      write_cache_stats(cache_root, runner.cache_store) if options.fetch(:cache_stats)

      exit_code = result.success? ? 0 : 1
      exit_code = 1 if baseline_strict_violation?(raw_result.diagnostics, configuration, options)
      exit_code
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
      cache_store = options.fetch(:no_cache) ? nil : Cache::Store.new(root: cache_root)
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
        treat_all_as_inline_rbs: false
      }
      parser = OptionParser.new do |opts| # rubocop:disable Metrics/BlockLength
        opts.banner = "Usage: rigor check [options] [paths]"
        opts.on("--config=PATH", "Path to the Rigor configuration file") { |value| options[:config] = value }
        opts.on("--format=FORMAT", "Output format: text or json") { |value| options[:format] = value }
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
      require_relative "analysis/runner"
      require_relative "analysis/buffer_binding"
      require_relative "analysis/baseline"
      require_relative "cache/store"
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

    def run_init
      # Default destination is `.rigor.dist.yml` — the
      # project-default config that gets committed. Developers
      # who want a personal override layer create `.rigor.yml`
      # alongside it (auto-discovery prefers `.rigor.yml` when
      # both are present; no implicit merge).
      options = {
        force: false,
        path: ".rigor.dist.yml"
      }

      parser = OptionParser.new do |opts|
        opts.banner = "Usage: rigor init [options]"
        opts.on("--force", "Overwrite an existing configuration file") { options[:force] = true }
        opts.on("--path=PATH", "Configuration file path") { |value| options[:path] = value }
      end
      parser.parse!(@argv)

      path = options.fetch(:path)
      if File.exist?(path) && !options.fetch(:force)
        @err.puts("#{path} already exists; use --force to overwrite it")
        return 1
      end

      File.write(path, init_template)
      @out.puts("Created #{path}")
      print_init_next_steps(path)
      0
    end

    # `rigor init`'s template ships empty `plugins:` so a fresh
    # init has nothing to validate — but the moment the user adds
    # any plugin entry, the activation-failure surfaces enumerated
    # in `rigor plugins`'s docstring become real. Point them at
    # the verification command + the canonical readiness flow so
    # silent failures (the cwd / Gemfile / signature_paths
    # mismatches that surfaced during the Mastodon trial) get
    # caught the first time the user wires a plugin, not the first
    # time `rigor check` reports false positives that should have
    # been covered.
    def print_init_next_steps(path)
      @out.puts ""
      @out.puts "Next steps:"
      @out.puts "  1. Edit #{path} — add the `plugins:` your project needs."
      @out.puts "  2. Run `rigor plugins` to verify every configured plugin loads."
      @out.puts "     (`--strict` exits 1 on failure; ideal CI gate.)"
      @out.puts "  3. Run `rigor check` to analyse your code."
    end

    # Renders the starter `.rigor.yml` body. The template
    # serialises `Configuration::DEFAULTS` (so the on-disk file
    # round-trips through `Configuration.load`) and prepends a
    # short header that points the user at the keys they are
    # most likely to want to edit.
    def init_template
      <<~YAML
        # yaml-language-server: $schema=https://github.com/zenwerk/rigor/raw/master/schemas/rigor-config.schema.json
        # Rigor configuration. See docs/CURRENT_WORK.md for the
        # full set of features the analyzer ships in this preview.
        #
        # Keys you may want to edit:
        # - target_ruby: minimum Ruby version your project targets.
        # - paths:       directories scanned by `rigor check` and
        #                `rigor type-scan` when no path is given.
        # - plugins:     reserved for future plugin contributions
        #                (no plugins are loaded today).
        # - disable:     list of `rigor check` rule identifiers to
        #                silence project-wide. The shipped rules are
        #                call.undefined-method, call.wrong-arity,
        #                call.argument-type-mismatch,
        #                call.possible-nil-receiver, dump.type,
        #                assert.type-mismatch, flow.always-raises.
        #                A bare family token (`call`, `flow`,
        #                `assert`, `dump`, `def`) wildcards every
        #                rule under that prefix. Legacy unprefixed
        #                names (`undefined-method`, …) still
        #                resolve. In-source
        #                `# rigor:disable <rule>` comments at the end
        #                of an offending line silence per-line; use
        #                `# rigor:disable all` to suppress every rule.
        # - libraries:   stdlib libraries to load on top of the
        #                bundled defaults (e.g. ["csv", "set"]).
        #                Each entry must be a name accepted by
        #                `RBS::EnvironmentLoader#has_library?`.
        # - signature_paths:
        #                explicit list of `sig/`-style directories.
        #                Leave unset (or `null`) to auto-detect
        #                `<root>/sig`. Use `[]` to disable
        #                project-RBS loading entirely.
        # - cache.path:  where Rigor will eventually persist
        #                analysis results across runs.
        #
        # `Rigor::Environment.for_project` automatically loads
        # the project's `sig/` directory plus a curated stdlib
        # bundle (pathname, optparse, json, yaml, fileutils,
        # tempfile, uri, logger, date, prism, rbs). Adding a
        # `sig/<gem>.rbs` file under `sig/` is the simplest way
        # to extend type coverage today.
        #{YAML.dump(Configuration::DEFAULTS).sub(/\A---\n/, '')}
      YAML
    end

    def run_annotate
      require_relative "cli/annotate_command"

      AnnotateCommand.new(argv: @argv, out: @out, err: @err).run
    end

    def run_type_of
      require_relative "cli/type_of_command"

      TypeOfCommand.new(argv: @argv, out: @out, err: @err).run
    end

    def run_type_scan
      require_relative "cli/type_scan_command"

      TypeScanCommand.new(argv: @argv, out: @out, err: @err).run
    end

    def run_explain
      require_relative "cli/explain_command"

      ExplainCommand.new(argv: @argv, out: @out, err: @err).run
    end

    def run_diff
      require_relative "cli/diff_command"

      DiffCommand.new(argv: @argv, out: @out, err: @err).run
    end

    def run_sig_gen
      require_relative "cli/sig_gen_command"

      SigGenCommand.new(argv: @argv, out: @out, err: @err).run
    end

    def run_lsp
      require_relative "cli/lsp_command"

      LspCommand.new(argv: @argv, out: @out, err: @err).run
    end

    def run_mcp
      require_relative "cli/mcp_command"

      McpCommand.new(argv: @argv, out: @out, err: @err).run
    end

    def run_baseline
      require_relative "cli/baseline_command"

      BaselineCommand.new(argv: @argv, out: @out, err: @err).run
    end

    def run_triage
      require_relative "cli/triage_command"

      CLI::TriageCommand.new(argv: @argv, out: @out, err: @err).run
    end

    def run_coverage
      require_relative "cli/coverage_command"

      CLI::CoverageCommand.new(argv: @argv, out: @out, err: @err).run
    end

    def run_plugins
      require_relative "cli/plugins_command"

      CLI::PluginsCommand.new(argv: @argv, out: @out, err: @err).run
    end

    def run_playground
      begin
        require "rigor/playground"
      rescue LoadError
        @err.puts "rigor playground requires the rigor-playground gem."
        @err.puts "Install it with: gem install rigor-playground"
        return EXIT_USAGE
      end
      Rigor::CLI::PlaygroundCommand.new(@argv[1..], @out, @err).run
    end

    def run_skill
      require_relative "cli/skill_command"

      CLI::SkillCommand.new(argv: @argv, out: @out, err: @err).run
    end

    def run_plugin
      require_relative "cli/plugin_command"

      CLI::PluginCommand.new(argv: @argv, out: @out, err: @err).run
    end

    def write_result(result, format)
      case format
      when "json"
        @out.puts(JSON.pretty_generate(result.to_h))
      when "text"
        write_text_result(result)
      else
        raise OptionParser::InvalidArgument, "unsupported format: #{format}"
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

    def help
      <<~HELP
        Usage: rigor <command> [options]

        Commands:
          check      Analyze Ruby source files
          init       Create a starter .rigor.yml
          annotate   Print FILE with each line's last-expression type
          type-of    Print the inferred type at FILE:LINE:COL
          type-scan  Report Scope#type_of coverage across PATHs
          explain    Print the description of one or all CheckRules
          diff       Compare current diagnostics to a saved baseline JSON
          sig-gen    Emit RBS skeletons inferred from .rb sources (ADR-14)
          lsp        Run the Rigor Language Server (LSP) over stdio
          mcp        Run the Rigor MCP server over stdio (ADR-33)
          triage     Summarise diagnostics: distribution, hotspots, hints (ADR-23)
          coverage   Report type-precision coverage (precise vs Dynamic ratio)
          plugins    Report activation status of every configured plugin
          plugin     Browse bundled plugin source as worked examples (list/path/print/root)
          playground Start the browser playground (requires rigor-playground gem)
          skill      List or print bundled Agent Skills (rigor-project-init, ...)
          version    Print the Rigor version
          help       Print this help
      HELP
    end
  end
end
