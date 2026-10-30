# frozen_string_literal: true

require "optparse"

require_relative "options"
require_relative "../version"

module Rigor
  class CLI
    # The machine-readable description of the CLI surface (ADR-126 WD3): one entry per command, with the one-line
    # summary, usage, subcommands, flags, accepted formats and the MCP tool that mirrors it.
    #
    # Nothing here is a second hand-written list of flags. The commands that parse with an `OptionParser` expose the
    # parser they build (`#option_parser`, built without parsing anything) and the catalogue reads its switches; the
    # commands that read `argv` by hand declare theirs in {DECLARED}. The only prose kept here is the one-line
    # {SUMMARIES}, which `rigor help` prints, so the text help and `rigor help --format=json` cannot disagree about
    # which commands exist. `spec/rigor/cli/catalogue_spec.rb` gates the names against `CLI::HANDLERS`.
    module Catalogue
      SCHEMA_VERSION = 1

      # `help` and `version` are dispatched by `CLI#run` itself, outside `CLI::HANDLERS`.
      BUILTINS = %w[help version].freeze

      # The `rigor help` listing, in print order.
      SUMMARIES = {
        "check" => "Analyze Ruby source files",
        "init" => "Create a starter .rigor.yml",
        "annotate" => "Print FILE with each line's last-expression type",
        "type-of" => "Print inferred types at FILE:LINE[:COL] positions",
        "lens" => "Map a file's declarations with their types and provenance (experimental)",
        "trace" => "Replay how the engine typed FILE as a terminal animation",
        "type-scan" => "Report Scope#type_of coverage across PATHs",
        "effects" => "Report each method's effect labels, and the committed effect snapshot " \
                     "(opt-in; effects update/check/diff/explain)",
        "explain" => "Print the description of one or all CheckRules",
        "diff" => "Compare current diagnostics to a saved baseline JSON",
        "baseline" => "Manage the baseline file (baseline generate/regenerate/dump/drift/prune)",
        "sig-gen" => "Emit RBS skeletons inferred from .rb sources",
        "lsp" => "Run the Rigor Language Server (LSP) over stdio",
        "mcp" => "Run the Rigor MCP server over stdio",
        "triage" => "Summarise diagnostics: distribution, hotspots, hints",
        "coverage" => "Report type-precision coverage (precise vs Dynamic ratio)",
        "unused" => "Report unreferenced classes, modules and constants as removal candidates",
        "plugins" => "Report activation status of every configured plugin",
        "plugin" => "Browse bundled plugin source as worked examples (list/path/print/root)",
        "playground" => "Start the browser playground (requires rigor-playground gem)",
        "describe" => "Recommend the next skill for this project (alias for `skill describe`)",
        "skill" => "Recommend the next skill + list/print bundled Agent Skills (skill describe, skill <name>)",
        "docs" => "Print the bundled docs offline (docs <name>, docs --list)",
        "show-bleedingedge" => "Show the bleeding-edge overlay + what your config adopts",
        "doctor" => "Classify setup problems vs clean run with routed next actions",
        "upgrade" => "Migration command skeleton (queued)",
        "version" => "Print the Rigor version",
        "help" => "Print this help, or a command's help (help <command>, help --format=json)"
      }.freeze

      # The commands whose `argv` is read by hand, so there is no parser to read: their switches, subcommands and
      # formats are stated here. `playground` is delegated to the optional `rigor-playground` gem and is listed without
      # flags.
      DECLARED = {
        "skill" => {
          usage: "Usage: rigor skill [<name>] [--full <name>] [--path <name>] [--list] [--describe]",
          subcommands: [{ name: "describe", usage: "Usage: rigor skill describe [--deep]" }],
          flags: [
            { name: "--full", arg: "NAME", desc: "Print the SKILL.md body and its references/ inline" },
            { name: "--path", arg: "NAME", desc: "Print the absolute path of the SKILL.md file" },
            { name: "--list", arg: nil, desc: "List bundled skills (name + absolute path)" },
            { name: "--describe", arg: nil, desc: "Report project state and recommend the next skill" }
          ]
        },
        "describe" => {
          usage: "Usage: rigor describe [--deep]",
          flags: [
            { name: "--deep", arg: nil, desc: "Run `rigor check` first and route the recommendation on its result" }
          ]
        },
        "docs" => {
          usage: "Usage: rigor docs [<name>] [--path <name>] [--list [<category>]]",
          flags: [
            { name: "--path", arg: "NAME", desc: "Print the absolute path of a doc" },
            { name: "--list", arg: "CATEGORY", optional: true, desc: "List bundled docs (optionally one category)" }
          ]
        },
        "plugin" => {
          usage: "Usage: rigor plugin <subcommand> [args]",
          subcommands: [
            { name: "list", usage: "Usage: rigor plugin list" },
            { name: "path", usage: "Usage: rigor plugin path <name>" },
            { name: "print", usage: "Usage: rigor plugin print <name>" },
            { name: "root", usage: "Usage: rigor plugin root" }
          ]
        },
        "playground" => { usage: "Usage: rigor playground [options]" },
        "version" => { usage: "Usage: rigor version" }
      }.freeze

      # The command files that build an `OptionParser`; the command class is the file's name in camel case.
      PARSER_FILES = %w[
        check annotate type_of lens trace type_scan effects explain diff sig_gen lsp mcp baseline triage coverage unused
        plugins show_bleedingedge doctor
      ].to_h { |file| [file.tr("_", "-"), "#{file}_command"] }.freeze

      # The commands that have no parser of their own at the top, so their usage is their `USAGE` constant.
      USAGE_FILES = { "baseline" => "baseline_command", "upgrade" => "upgrade_command" }.freeze

      Ractor.make_shareable(SUMMARIES)
      Ractor.make_shareable(USAGE_FILES)
      Ractor.make_shareable(DECLARED)
      Ractor.make_shareable(PARSER_FILES)

      module_function

      # Every command name the CLI dispatches, in `rigor help` order.
      def names
        SUMMARIES.keys - BUILTINS + BUILTINS
      end

      # The `rigor help` text, rendered from {SUMMARIES} so its list is the catalogue's.
      def help_text
        width = names.map(&:length).max + 2
        lines = names.map { |name| "  #{name.ljust(width)}#{SUMMARIES.fetch(name)}" }
        <<~HELP
          Usage: rigor <command> [options]

          Commands:
          #{lines.join("\n")}

          Run `rigor help <command>` (or `rigor <command> --help`) for a command's options.
          Run `rigor describe` for the next step on this project, or `rigor help --format=json` for the full surface.
        HELP
      end

      # All entries, as plain hashes ready for JSON.
      def entries
        names.map { |name| entry(name) }
      end

      # The document `rigor help --format=json` prints.
      def document
        { "schema_version" => SCHEMA_VERSION, "version" => Rigor::VERSION, "commands" => entries }
      end

      def entry(name)
        declared = DECLARED.fetch(name, {})
        parsed = parsed_entry(name)
        {
          "name" => name,
          "summary" => SUMMARIES.fetch(name),
          "usage" => declared[:usage] || parsed[:usage] || command_usage(name),
          "subcommands" => parsed[:subcommands] || declared_subcommands(declared),
          "flags" => parsed[:flags] || declared_flags(declared),
          "formats" => parsed[:formats] || [],
          "mcp_tool" => mcp_tool(name)
        }
      end

      # The `OptionParser` view of a command: its own flags and formats at the top, and under `subcommands` the same
      # shape for each subcommand's parser. A command with no parser of its own (`baseline`) has empty top-level
      # `flags` and `formats`; none of them is a union over its subcommands.
      def parsed_entry(name)
        pairs = parser_pairs(name)
        return {} if pairs.nil?

        own = pairs.find { |sub, _| sub.nil? }&.last
        subs = pairs.reject { |sub, _| sub.nil? }
        top = own ? describe_parser(own) : { flags: [], formats: [] }
        return top if subs.empty?

        top.merge(subcommands: subs.map do |sub, parser|
          { "name" => sub }.merge(stringify_keys(describe_parser(parser)))
        end)
      end

      # The `[subcommand, parser]` pairs of a command (no name for its own parser), or nil when it has no parser.
      def parser_pairs(name)
        case name
        when "init" then [[nil, CLI.init_option_parser]]
        when "help" then [[nil, CLI.help_option_parser]]
        else command_parser_pairs(name)
        end
      end

      def command_parser_pairs(name)
        file = PARSER_FILES[name]
        return nil unless file

        require_relative file
        klass = CLI.const_get(file.split("_").map(&:capitalize).join)
        case name
        when "effects" then effects_parser_pairs(klass)
        when "baseline"
          command = klass.new(argv: [])
          klass::SUBCOMMANDS.map { |sub| [sub, command.option_parser(sub)] }
        else [[nil, klass.new(argv: []).option_parser]]
        end
      end

      def effects_parser_pairs(klass)
        [[nil, klass.new(argv: []).option_parser]] +
          EffectsSnapshotCommand::VERBS.map do |verb|
            [verb, EffectsSnapshotCommand.new(argv: [], verb: verb).option_parser]
          end
      end

      # The usage line of a command with no parser to take a banner from, read from the command's own `USAGE`.
      def command_usage(name)
        file = USAGE_FILES[name]
        return nil unless file

        require_relative file
        CLI.const_get(file.split("_").map(&:capitalize).join)::USAGE
      end

      def declared_flags(declared)
        (declared[:flags] || []).map do |flag|
          { "name" => flag.fetch(:name), "arg" => flag.fetch(:arg), "optional" => flag.fetch(:optional, false),
            "desc" => flag.fetch(:desc) }
        end
      end

      def declared_subcommands(declared)
        (declared[:subcommands] || []).map do |sub|
          { "name" => sub.fetch(:name), "usage" => sub.fetch(:usage), "flags" => [], "formats" => [] }
        end
      end

      # Reads usage, flags and formats from the switches of `parser`.
      def describe_parser(parser)
        flags = parser.top.list.flat_map { |switch| flags_of(switch) }
        format_switch = parser.top.list.any? { |switch| switch.long.first == "--format" }
        { usage: parser.banner.to_s.lines.first&.strip, flags: flags,
          formats: format_switch ? Options.accepted_formats(parser) || [] : [] }
      end

      # A switch's literal flags: `--[no-]color` is the two flags `--color` and `--no-color`.
      def flags_of(switch)
        long = switch.long.first
        return [] unless long

        arg, optional = arg_of(switch.arg)
        desc = switch.desc.join(" ")
        flag_names(long).map { |flag| { "name" => flag, "arg" => arg, "optional" => optional, "desc" => desc } }
      end

      # `[arg, optional]`: `=[LIST]` is the argument `LIST`, optional.
      def arg_of(raw)
        arg = raw&.sub(/\A[= ]/, "")
        optional = !arg.nil? && arg.start_with?("[") && arg.end_with?("]")
        [optional ? arg[1..-2] : arg, optional]
      end

      def flag_names(long)
        return [long] unless long.start_with?("--[no-]")

        bare = long.delete_prefix("--[no-]")
        ["--#{bare}", "--no-#{bare}"]
      end

      # `rigor_check` mirrors `check`, `rigor_sig_gen` mirrors `sig-gen`: a tool is named for its command.
      def mcp_tool(name)
        require_relative "../mcp/server"
        tool = "rigor_#{name.tr('-', '_')}"
        tool if MCP::Server::TOOLS.any? { |candidate| candidate.fetch(:name) == tool }
      end

      def stringify_keys(hash)
        hash.transform_keys(&:to_s)
      end
    end
  end
end
