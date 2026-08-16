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
require_relative "cli/diagnostic_formats"
require_relative "ci_detector"

module Rigor
  # The CLI class is a dispatcher: each `run_*` method delegates to a command-specific class once the command grows
  # beyond a few lines (see {CLI::TypeOfCommand} and {CLI::CheckCommand}). It necessarily grows by one delegator + one
  # help line per command, so — like the command classes it fans out to — it carries an explicit ClassLength exemption.
  class CLI # rubocop:disable Metrics/ClassLength
    EXIT_USAGE = 64

    # The published location of `schemas/rigor-config.schema.json`, written into the `.rigor.yml` that
    # `rigor init` generates so an editor validates the file as the user types.
    #
    # This MUST equal the schema's own `$id`, and it MUST resolve. Both are gated
    # (`spec/rigor/config_schema_spec.rb`) because neither failure has a symptom: an unreachable schema
    # is indistinguishable from a schema with no complaints, so a stale URL here silently disables
    # validation for every project that ran `rigor init`. It pointed at a nonexistent org until
    # 2026-07-17 and nothing noticed. See `docs/internal-spec/config.md`.
    CONFIG_SCHEMA_URL = "https://github.com/rigortype/rigor/raw/master/schemas/rigor-config.schema.json"

    HANDLERS = {
      "check" => :run_check,
      "init" => :run_init,
      "annotate" => :run_annotate,
      "type-of" => :run_type_of,
      "trace" => :run_trace,
      "type-scan" => :run_type_scan,
      "effects" => :run_effects,
      "explain" => :run_explain,
      "diff" => :run_diff,
      "sig-gen" => :run_sig_gen,
      "lsp" => :run_lsp,
      "mcp" => :run_mcp,
      "baseline" => :run_baseline,
      "triage" => :run_triage,
      "unused" => :run_unused,
      "coverage" => :run_coverage,
      "plugins" => :run_plugins,
      "plugin" => :run_plugin,
      "playground" => :run_playground,
      "skill" => :run_skill,
      "describe" => :run_describe,
      "docs" => :run_docs,
      "show-bleedingedge" => :run_show_bleedingedge,
      "doctor" => :run_doctor,
      "upgrade" => :run_upgrade
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
      require_relative "cli/check_command"

      CheckCommand.new(argv: @argv, out: @out, err: @err).run
    end

    def run_init
      # Default destination is `.rigor.dist.yml` — the project-default config that gets committed. Developers who want a
      # personal override layer create `.rigor.yml` alongside it (auto-discovery prefers `.rigor.yml` when both are
      # present; no implicit merge).
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

    # `rigor init`'s template ships empty `plugins:` so a fresh init has nothing to validate — but the moment the user
    # adds any plugin entry, the activation-failure surfaces enumerated in `rigor plugins`'s docstring become real.
    # Point them at the verification command + the canonical readiness flow so silent failures (the cwd / Gemfile /
    # signature_paths mismatches that surfaced during the Mastodon trial) get caught the first time the user wires a
    # plugin, not the first time `rigor check` reports false positives that should have been covered.
    def print_init_next_steps(path)
      @out.puts ""
      @out.puts "Next steps:"
      @out.puts "  1. Edit #{path} — add the `plugins:` your project needs."
      @out.puts "  2. Run `rigor plugins` to verify every configured plugin loads."
      @out.puts "     (`--strict` exits 1 on failure; ideal CI gate.)"
      @out.puts "  3. Run `rigor check` to analyse your code."
    end

    # Renders the starter `.rigor.yml` body. The template serialises `Configuration::DEFAULTS` (so the on-disk file
    # round-trips through `Configuration.load`) and prepends a short header that points the user at the keys they are
    # most likely to want to edit.
    def init_template
      <<~YAML
        # yaml-language-server: $schema=#{CONFIG_SCHEMA_URL}
        # Rigor configuration. The full key reference is
        # https://github.com/rigortype/rigor/blob/master/docs/manual/03-configuration.md
        # (or run `rigor docs configuration`).
        #
        # Keys you may want to edit:
        # - target_ruby: minimum Ruby version your project targets.
        # - paths:       directories scanned by `rigor check` and
        #                `rigor type-scan` when no path is given.
        # - plugins:     opt-in list of plugin gem names to load.
        #                See https://github.com/rigortype/rigor/tree/main/plugins
        #                for production plugins (rigor-activerecord, rigor-sorbet, …).
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

    def run_trace
      require_relative "cli/trace_command"

      TraceCommand.new(argv: @argv, out: @out, err: @err).run
    end

    def run_type_scan
      require_relative "cli/type_scan_command"

      TypeScanCommand.new(argv: @argv, out: @out, err: @err).run
    end

    def run_effects
      require_relative "cli/effects_command"

      EffectsCommand.new(argv: @argv, out: @out, err: @err).run
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

    def run_unused
      require_relative "cli/unused_command"

      CLI::UnusedCommand.new(argv: @argv, out: @out, err: @err).run
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

    # `rigor describe` — a top-level alias for `rigor skill describe`, the entry point most users reach for first.
    # Surfaced because a bare `rigor describe` is the intuitive guess (the onboarding field trial saw it tried and met
    # "Unknown command").
    def run_describe
      require_relative "cli/skill_command"

      CLI::SkillCommand.new(argv: ["describe", *@argv], out: @out, err: @err).run
    end

    def run_docs
      require_relative "cli/docs_command"

      CLI::DocsCommand.new(argv: @argv, out: @out, err: @err).run
    end

    def run_plugin
      require_relative "cli/plugin_command"

      CLI::PluginCommand.new(argv: @argv, out: @out, err: @err).run
    end

    def run_show_bleedingedge
      require_relative "cli/show_bleedingedge_command"

      CLI::ShowBleedingedgeCommand.new(argv: @argv, out: @out, err: @err).run
    end

    def run_doctor
      require_relative "cli/doctor_command"

      CLI::DoctorCommand.new(argv: @argv, out: @out, err: @err).run
    end

    def run_upgrade
      require_relative "cli/upgrade_command"

      CLI::UpgradeCommand.new(argv: @argv, out: @out, err: @err).run
    end

    def help
      <<~HELP
        Usage: rigor <command> [options]

        Commands:
          check      Analyze Ruby source files
          init       Create a starter .rigor.yml
          annotate   Print FILE with each line's last-expression type
          type-of    Print the inferred type at FILE:LINE:COL
          trace      Replay how the engine typed FILE as a terminal animation
          type-scan  Report Scope#type_of coverage across PATHs
          effects    Report each method's effect labels, and the committed effect snapshot
                     (ADR-103, opt-in; effects update/check/diff/explain)
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
          describe   Recommend the next skill for this project (alias for `skill describe`)
          skill      Recommend the next skill + list/print bundled Agent Skills (skill describe, skill <name>)
          docs       Print the bundled docs offline (docs <name>, docs --list)
          show-bleedingedge  Show the bleeding-edge overlay + what your config adopts (ADR-50)
          doctor     Classify setup problems vs clean run with routed next actions (ADR-77)
          upgrade    Migration command skeleton (ADR-50 WD7, queued)
          version    Print the Rigor version
          help       Print this help
      HELP
    end
  end
end
