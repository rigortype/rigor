# frozen_string_literal: true

require "fileutils"
require "json"
require "optionparser"
require "yaml"

require_relative "configuration"
require_relative "version"
require_relative "analysis/diagnostic"
require_relative "analysis/result"

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
      "type-of" => :run_type_of,
      "type-scan" => :run_type_scan,
      "explain" => :run_explain,
      "diff" => :run_diff,
      "sig-gen" => :run_sig_gen
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
      require_relative "analysis/runner"
      require_relative "cache/store"

      options = parse_check_options

      configuration = Configuration.load(options.fetch(:config))
      cache_root = configuration.cache_path
      handle_clear_cache(cache_root) if options.fetch(:clear_cache)
      cache_store = options.fetch(:no_cache) ? nil : Cache::Store.new(root: cache_root)

      paths = @argv.empty? ? configuration.paths : @argv
      runner = Analysis::Runner.new(
        configuration: configuration,
        explain: options.fetch(:explain),
        cache_store: cache_store,
        collect_stats: options.fetch(:stats),
        workers: resolve_workers(options, configuration)
      )
      result = runner.run(paths)

      write_result(result, options.fetch(:format))
      write_run_stats(result.stats) if result.stats
      write_cache_stats(cache_root, runner.cache_store) if options.fetch(:cache_stats)
      result.success? ? 0 : 1
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

    def parse_check_options
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
        workers: nil
      }
      parser = OptionParser.new do |opts|
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
      end
      parser.parse!(@argv)
      options
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
      0
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
          type-of    Print the inferred type at FILE:LINE:COL
          type-scan  Report Scope#type_of coverage across PATHs
          explain    Print the description of one or all CheckRules
          diff       Compare current diagnostics to a saved baseline JSON
          sig-gen    Emit RBS skeletons inferred from .rb sources (ADR-14)
          version    Print the Rigor version
          help       Print this help
      HELP
    end
  end
end
