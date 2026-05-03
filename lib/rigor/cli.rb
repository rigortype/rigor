# frozen_string_literal: true

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
      "type-scan" => :run_type_scan
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

      options = {
        config: Configuration::DEFAULT_PATH,
        format: "text",
        explain: false
      }

      parser = OptionParser.new do |opts|
        opts.banner = "Usage: rigor check [options] [paths]"
        opts.on("--config=PATH", "Path to the Rigor configuration file") { |value| options[:config] = value }
        opts.on("--format=FORMAT", "Output format: text or json") { |value| options[:format] = value }
        opts.on("--explain", "Surface fail-soft fallback events as :info diagnostics") { options[:explain] = true }
      end
      parser.parse!(@argv)

      configuration = Configuration.load(options.fetch(:config))
      paths = @argv.empty? ? configuration.paths : @argv
      result = Analysis::Runner.new(configuration: configuration, explain: options.fetch(:explain)).run(paths)

      write_result(result, options.fetch(:format))
      result.success? ? 0 : 1
    end

    def run_init
      options = {
        force: false,
        path: Configuration::DEFAULT_PATH
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
        #                undefined-method, wrong-arity,
        #                argument-type-mismatch, possible-nil-receiver,
        #                dump-type, assert-type. In-source
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
          version    Print the Rigor version
          help       Print this help
      HELP
    end
  end
end
