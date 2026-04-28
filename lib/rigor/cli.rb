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

    def initialize(argv, out:, err:)
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
        format: "text"
      }

      parser = OptionParser.new do |opts|
        opts.banner = "Usage: rigor check [options] [paths]"
        opts.on("--config=PATH", "Path to the Rigor configuration file") { |value| options[:config] = value }
        opts.on("--format=FORMAT", "Output format: text or json") { |value| options[:format] = value }
      end
      parser.parse!(@argv)

      configuration = Configuration.load(options.fetch(:config))
      paths = @argv.empty? ? configuration.paths : @argv
      result = Analysis::Runner.new(configuration: configuration).run(paths)

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

      File.write(path, YAML.dump(Configuration::DEFAULTS))
      @out.puts("Created #{path}")
      0
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
        if result.success?
          @out.puts("No diagnostics")
        else
          result.diagnostics.each { |diagnostic| @out.puts(diagnostic) }
        end
      else
        raise OptionParser::InvalidArgument, "unsupported format: #{format}"
      end
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
