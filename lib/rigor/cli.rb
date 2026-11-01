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
require "did_you_mean"

require_relative "cli/catalogue"
require_relative "cli/diagnostic_formats"
require_relative "ci_detector"
require_relative "analysis/check_rules/rule_ids"

module Rigor
  # The CLI class is a dispatcher: each `run_*` method delegates to a command-specific class once the command grows
  # beyond a few lines (see {CLI::TypeOfCommand} and {CLI::CheckCommand}). It necessarily grows by one delegator + one
  # help line per command, so — like the command classes it fans out to — it carries an explicit ClassLength exemption.
  class CLI # rubocop:disable Metrics/ClassLength
    EXIT_USAGE = 64

    # Issue [#609](https://github.com/rigortype/rigor/issues/609) — a run the analyzer could not finish.
    # Distinct from `1` (the analysis ran and reported diagnostics) so a CI step can tell "your code has
    # findings" from "Rigor died and this report is not an account of anything".
    EXIT_INTERNAL_ERROR = 70

    # The exceptions that mean "the process is out of a resource, and the backtrace names nothing
    # actionable": `SystemStackError` from an ancestry walk that never terminates, `NoMemoryError` from a
    # runaway allocation. Neither is a `StandardError`, so every rescue between here and the raise site
    # declines them by design — the whole point of those rescues is to convert a per-file or per-plugin
    # failure into a diagnostic, and a process running out of stack is not per-file. Left uncaught they
    # abort with Ruby's own ~40-frame dump, which is non-zero (so a CI gate does catch it) but says
    # neither that Rigor is at fault nor that the report on disk is empty. `Interrupt`, `SignalException`
    # and `SystemExit` stay out: those are the user's answer, not a failure.
    FATAL_ERRORS = [SystemStackError, NoMemoryError].freeze

    # The published location of `schemas/rigor-config.schema.json`, written into the `.rigor.yml` that
    # `rigor init` generates so an editor validates the file as the user types.
    #
    # This MUST equal the schema's own `$id`, and it MUST resolve. Both are gated
    # (`spec/rigor/config_schema_spec.rb`) because neither failure has a symptom: an unreachable schema
    # is indistinguishable from a schema with no complaints, so a stale URL here silently disables
    # validation for every project that ran `rigor init`. It pointed at a nonexistent org until
    # 2026-07-17 and nothing noticed. See `docs/internal-spec/config.md`.
    CONFIG_SCHEMA_URL = "https://github.com/rigortype/rigor/raw/master/schemas/rigor-config.schema.json"

    # The comment `rigor init` writes under `plugins: []` when Gemfile.lock names a gem a bundled plugin models. The
    # plugins are suggested, not enabled: ADR-96 Criterion 2 keeps a lockfile's presence from opting a project into a
    # plugin's code, so the user uncomments the ones they want (#2536).
    DETECTED_PLUGINS_HEADER = [
      "# Detected from Gemfile.lock (suggested, not enabled). To load them, delete the `[]` above, uncomment the",
      "# entries you want, then run `rigor plugins --strict`."
    ].freeze

    HANDLERS = {
      "check" => :run_check,
      "init" => :run_init,
      "annotate" => :run_annotate,
      "type-of" => :run_type_of,
      "lens" => :run_lens,
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

    # The parser `rigor init` parses with, built without parsing anything (the catalogue reads it, ADR-126 WD3).
    def self.init_option_parser(options = {})
      OptionParser.new do |opts|
        opts.banner = "Usage: rigor init [options]"
        opts.on("--force", "Overwrite an existing configuration file") { options[:force] = true }
        opts.on("--path=PATH", "Configuration file path") { |value| options[:path] = value }
        opts.on("--no-plugins", "Write no commented plugin suggestions from Gemfile.lock") do
          options[:plugins] = false
        end
      end
    end

    # The parser `rigor help` parses with, built without parsing anything (the catalogue reads it, ADR-126 WD3).
    def self.help_option_parser(options = {})
      OptionParser.new do |opts|
        opts.banner = "Usage: rigor help [--format=text|json] [<command>]"
        Options.add_format(opts, options, "Output format: text (default) or json")
      end
    end

    def initialize(argv = ARGV.dup, out: $stdout, err: $stderr)
      @argv = argv
      @out = out
      @err = err
    end

    def run
      command = @argv.shift

      case command
      when nil, "-h", "--help"
        @out.puts(help)
        0
      when "help"
        run_help
      when "version", "-v", "--version"
        run_version

      else
        dispatch(command)
      end
    rescue OptionParser::ParseError => e
      @err.puts(e.message)
      EXIT_USAGE
    rescue ConfigurationError => e
      # #433 — a mistake in `.rigor.yml` is the same kind of event as a bad flag, and belongs in the same
      # shape: one `rigor:` line naming the key, and the conventional usage exit code. It used to escape
      # as an uncaught exception with a ~30-frame backtrace naming a file inside `lib/rigor/`, which reads
      # as a crash even though the message it carried said exactly which key to fix.
      #
      # Caught here rather than per command because every command loads a configuration, and the ones
      # that resolve a key later (`effects update` expanding `snapshot.reach:` once the plugins that
      # register presets have loaded) would each need their own rescue at their own point.
      @err.puts("rigor: #{e.message}")
      EXIT_USAGE
    rescue *FATAL_ERRORS => e
      report_fatal_error(e)
      EXIT_INTERNAL_ERROR
    end

    private

    # One `rigor:` line naming the failure, then the innermost frames — enough to route a bug report,
    # without the full dump the raise would otherwise print. The "no report" sentence is the part a user
    # acts on: the crash usually happens with a redirect in place, so the artifact a CI step goes on to
    # read is an empty file rather than a missing one.
    def report_fatal_error(error)
      @err.puts("rigor: analysis aborted: #{error.class}: #{error.message}")
      Array(error.backtrace).first(FATAL_BACKTRACE_FRAMES).each { |frame| @err.puts("  from #{frame}") }
      @err.puts("  Rigor could not finish this run, so its report is EMPTY rather than clean — do not")
      @err.puts("  read this exit status as a passing check.")
      @err.puts("  This is a defect in Rigor; please report it at https://github.com/rigortype/rigor/issues.")
    end

    FATAL_BACKTRACE_FRAMES = 5
    private_constant :FATAL_BACKTRACE_FRAMES

    def dispatch(command)
      handler = HANDLERS[command]
      return arm_jit_deadline { send(handler) } if handler

      @err.puts("Unknown command: #{command}")
      nearest = ::DidYouMean::SpellChecker.new(dictionary: Catalogue.names).correct(command).first
      @err.puts("Did you mean `rigor #{nearest}`?") if nearest
      @err.puts(help)
      EXIT_USAGE
    end

    # Deferred YJIT for EVERY dispatched command, not just `check` / `coverage` where PR #75 first
    # calibrated it. The deadline makes the decision command-independent: a run that finishes inside
    # the window never pays JIT compile, and a run that outlasts it JITs its dominant tail — measured
    # on `rigor effects` cold over Mastodon, which ran its whole 21 s interpreted while the same
    # analysis under `check` took 14.8 s (forcing YJIT on the effects run: 15.9 s; disabling it on
    # check: 21.1 s). `lsp` / `mcp` still call `Runtime::Jit.enable_now` at boot, which makes the
    # deadline thread armed here a no-op when it later fires.
    def arm_jit_deadline
      require_relative "runtime/jit"
      Runtime::Jit.enable_after(Runtime::Jit.deadline_seconds)
      yield
    end

    # `rigor version` and `-v`/`--version` print the version; `rigor version --help` prints the usage instead.
    def run_version
      if @argv.intersect?(%w[-h --help])
        @out.puts("Usage: rigor version")
      else
        @out.puts("rigor #{Rigor::VERSION}")
      end
      0
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
        path: ".rigor.dist.yml",
        plugins: true
      }

      self.class.init_option_parser(options).parse!(@argv)

      path = options.fetch(:path)
      if File.exist?(path) && !options.fetch(:force)
        @err.puts("#{path} already exists; use --force to overwrite it")
        return 1
      end

      plugins = options.fetch(:plugins) ? detected_plugins : []
      begin
        File.write(path, init_template(path, plugins: plugins))
      rescue SystemCallError => e
        # A destination whose directory is missing or not writable is a bad path argument, the same usage error
        # `--config=PATH` gives for a file that does not exist (exit 64, docs/manual/02-cli-reference.md). The bare
        # Errno::ENOENT backtrace read as an internal crash.
        reason = e.message.sub(/ @ .*\z/m, "")
        @err.puts("rigor init: cannot write #{path}: #{reason}")
        return EXIT_USAGE
      end
      @out.puts("Created #{path}")
      print_init_next_steps(path, plugins)
      0
    end

    # The bundled plugins whose target gems the project's `Gemfile.lock` declares: the read `rigor doctor` makes,
    # through {PluginGapAdvisory}, so the two cannot disagree about what the project depends on. Empty without a
    # lockfile, which leaves the template as it was before detection existed. The advisory is required lazily:
    # it loads every bundled plugin's entry file, a cost a plain `rigor init` in a directory with no lockfile never
    # pays.
    def detected_plugins
      require_relative "plugin_gap_advisory"

      PluginGapAdvisory.gaps(project_root: Dir.pwd, plugins: []).map(&:plugin_gem)
    end

    # `rigor init`'s template lists the plugins Gemfile.lock detected, or ships empty `plugins:` so a fresh init has
    # nothing to validate — but the moment the user adds any plugin entry, the activation-failure surfaces enumerated
    # in `rigor plugins`'s docstring become real.
    # Point them at the verification command + the canonical readiness flow so silent failures (the cwd / Gemfile /
    # signature_paths mismatches that surfaced during the Mastodon trial) get caught the first time the user wires a
    # plugin, not the first time `rigor check` reports false positives that should have been covered.
    def print_init_next_steps(path, plugins = [])
      @out.puts ""
      @out.puts "Next steps:"
      if plugins.empty?
        @out.puts "  1. Edit #{path} — add the `plugins:` your project needs."
      else
        @out.puts "  1. Edit #{path} — to load a detected plugin, delete the `[]` on the `plugins:` line and"
        @out.puts "     uncomment the entries you want:"
        plugins.each { |gem| @out.puts "       #{gem}" }
      end
      @out.puts "  2. Run `rigor plugins` to verify every configured plugin loads."
      @out.puts "     (`--strict` exits 1 on failure; ideal CI gate.)"
      @out.puts "  3. Run `rigor check` to analyse your code."
    end

    # Word-wraps `CheckRules::ALL_RULES` into a comma-separated, `#`-commented block for `init_template`, so the
    # listed rule ids cannot drift from the catalogue the way a hand-picked subset did (#920) — every rule and only
    # a rule actually in `ALL_RULES` gets named here.
    def rule_ids_comment
      prefix = "#                "
      max_width = 78 - prefix.length
      ids = Analysis::CheckRules::ALL_RULES
      lines = []
      current = +""
      ids.each_with_index do |id, index|
        token = "#{id}#{index == ids.length - 1 ? '.' : ','}"
        if current.empty?
          current = token
        elsif current.length + 1 + token.length <= max_width
          current << " " << token
        else
          lines << current
          current = token
        end
      end
      lines << current unless current.empty?
      lines.map { |line| "#{prefix}#{line}" }.join("\n")
    end

    # Renders the starter `.rigor.yml` body. The template serialises `Configuration::DEFAULTS` (so the on-disk file
    # round-trips through `Configuration.load`) and prepends a short header that points the user at the keys they are
    # most likely to want to edit. `plugins:` stays the empty list the defaults ship; detected gems appear beneath it as
    # comments, so a project with no lockfile gets the template it always did.
    def init_template(path = ".rigor.dist.yml", plugins: [])
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
        #                See https://github.com/rigortype/rigor/tree/master/plugins
        #                for production plugins (rigor-activerecord, rigor-sorbet, …).
        # - disable:     list of `rigor check` rule identifiers to
        #                silence project-wide. Every rule id Rigor
        #                ships (run `rigor explain <rule>` for what
        #                each one catches):
        #{rule_ids_comment}
        #                A bare family token (`call`, `flow`, `def`,
        #                `assert`, `dump`, `global`, `suppression`,
        #                `static`, `effect`, `pre-eval`) wildcards every
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
        # - test_paths:  the directories holding your tests.
        #                `rigor sig-gen --params=observed` reads
        #                their call sites to type parameters.
        #                `rigor init` writes the spec/ and test/
        #                it finds; unset auto-detects them, and
        #                `[]` declares the project has none.
        # - cache.path:  where Rigor will eventually persist
        #                analysis results across runs.
        #
        # `Rigor::Environment.for_project` automatically loads
        # the project's `sig/` directory plus a curated stdlib
        # bundle (pathname, optparse, json, yaml, fileutils,
        # tempfile, uri, logger, date, prism, rbs). Adding a
        # `sig/<gem>.rbs` file under `sig/` is the simplest way
        # to extend type coverage today.
        #
        # `target_ruby` is left commented: the default only picks the syntax Rigor parses. Set it to the lowest
        # Ruby your project runs on, and Rigor also reports what that Ruby deprecates.
        # target_ruby: #{Configuration::DEFAULTS.fetch('target_ruby').dump}
        #{settings_yaml(path, plugins)}
      YAML
    end

    # The serialised settings. `plugins: []` stays valid YAML and schema-clean; when `Gemfile.lock` named a modelled
    # gem, the suggestion block sits under it as comments, so nothing loads until the user uncomments a line.
    def settings_yaml(path, plugins)
      yaml = YAML.dump(init_settings(path)).sub(/\A---\n/, "")
      return yaml if plugins.empty?

      yaml.sub(/^plugins: \[\]\n/) { "plugins: []\n#{detected_plugins_block(plugins)}" }
    end

    def detected_plugins_block(plugins)
      lines = DETECTED_PLUGINS_HEADER + plugins.map { |gem| "#   - #{gem}" }
      lines.map { |line| "#{line}\n" }.join
    end

    # The settings `rigor init` writes: the defaults, with `test_paths:` spelled out as the test roots found now, so
    # the project's config says where its tests are rather than leaving it to auto-detection. The roots are written
    # relative to the config file's directory, which is what {Configuration.load} resolves them against. `paths:`
    # is written the same way: the default `lib` is resolved against the physical cwd, so a config written to
    # `config/rigor.yml` must say `../lib`, or it loads back as `config/lib` (#1399).
    #
    # `target_ruby` is left out (the template writes it commented): a written key is a statement about the runtime
    # (#1692), and the starter must not make one the user never chose.
    def init_settings(path)
      config_dir = config_dir_of(path)
      settings = Configuration::DEFAULTS.except("target_ruby")
      settings = settings.merge("paths" => roots_relative_to(settings.fetch("paths"), config_dir))
      test_paths = Configuration.new.resolved_test_paths
      return settings if test_paths.empty?

      settings.merge("test_paths" => roots_relative_to(test_paths, config_dir))
    end

    # The directory the config file's roots are written relative to. An absolute `--path` is taken through its
    # physical directory: the roots are resolved against the physical cwd (`Dir.pwd` is getcwd), so a logical
    # spelling through a symlink makes the lexical `..` climb a different tree than the kernel does (#1399 review).
    # A relative `--path` stays lexical, as {Configuration.load} resolves it.
    def config_dir_of(path)
      dir = File.dirname(path)
      Pathname(Pathname(path).absolute? ? File.realdirpath(dir) : File.absolute_path(dir))
    end

    # Each root is resolved against the physical cwd (where `rigor` reads it from), then written relative to the config
    # dir. With the config at the project root, both sides are the same physical directory, so the roots come out as
    # they are spelled from it (`lib`, `spec`).
    def roots_relative_to(roots, config_dir)
      roots.map { |root| Pathname(File.absolute_path(root)).relative_path_from(config_dir).to_s }
    end

    def run_annotate
      require_relative "cli/annotate_command"

      AnnotateCommand.new(argv: @argv, out: @out, err: @err).run
    end

    def run_type_of
      require_relative "cli/type_of_command"

      TypeOfCommand.new(argv: @argv, out: @out, err: @err).run
    end

    def run_lens
      require_relative "cli/lens_command"

      LensCommand.new(argv: @argv, out: @out, err: @err).run
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
      # `run` shifts the verb off `@argv` before dispatching, so the handler receives the arguments
      # already. Slicing here dropped the first one — `rigor playground --port=4000` served the
      # default port, and a bare `rigor playground` passed `nil` into a command that iterates it.
      Rigor::CLI::PlaygroundCommand.new(@argv, @out, @err).run
    end

    def run_skill
      require_relative "cli/skill_command"

      CLI::SkillCommand.new(argv: @argv, out: @out, err: @err).run
    end

    # `rigor describe` — a top-level alias for `rigor skill describe`, the entry point most users reach for first.
    # Surfaced because a bare `rigor describe` is the intuitive guess (the onboarding field trial saw it tried and met
    # "Unknown command").
    def run_describe
      return print_describe_usage if @argv.intersect?(%w[-h --help])

      require_relative "cli/skill_command"

      CLI::SkillCommand.new(argv: ["describe", *@argv], out: @out, err: @err).run
    end

    def print_describe_usage
      @out.puts("Usage: rigor describe [--deep]")
      0
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

    # The text help is rendered from {Catalogue}, so the command list cannot drift from the dispatch table.
    def help
      Catalogue.help_text
    end

    # `rigor help [--format=text|json] [<command>]`. `help <command>` behaves as `rigor <command> --help`;
    # `--format=json` prints the whole {Catalogue} document.
    def run_help
      return print_command_list if @argv.intersect?(%w[-h --help])

      options = parse_help_options
      topics = @argv
      return run_help_json(topics) if options[:format] == "json"

      topic = topics.first
      return run_help_topic(topic, topics.drop(1)) if topic

      print_command_list
    end

    def print_command_list
      @out.puts(help)
      0
    end

    def parse_help_options
      options = Hash.new("text")
      # `order!` stops at the first positional, so the flags of the command being asked about are never parsed here.
      self.class.help_option_parser(options).order!(@argv)
      options
    end

    def run_help_json(topics)
      if topics.any?
        @err.puts("rigor help --format=json takes no command; it prints every command")
        return EXIT_USAGE
      end

      @out.puts(JSON.pretty_generate(Catalogue.document))
      0
    end

    def run_help_topic(topic, rest)
      # Flags after the command name (`help type-of --workers=2`) are not parsed; a second word is not a subcommand's
      # help, so it is refused rather than answered with the parent's.
      extra = rest.reject { |word| word.start_with?("-") }
      unless extra.empty?
        @err.puts("rigor help takes one command, got: #{[topic, *extra].join(' ')}")
        return EXIT_USAGE
      end

      case topic
      when "help"
        @out.puts(self.class.help_option_parser.help)
        0
      when "version"
        @out.puts("Usage: rigor version")
        0
      when *HANDLERS.keys
        @argv = ["--help"]
        dispatch(topic)
      else
        @err.puts("Unknown command: #{topic}")
        @err.puts(help)
        EXIT_USAGE
      end
    end
  end
end
