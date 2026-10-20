# frozen_string_literal: true

require_relative "../analysis/buffer_binding"
require_relative "../configuration_error"

module Rigor
  class CLI
    # Shared option plumbing for the subcommands.
    #
    # Today it owns the editor-mode surface that `rigor check` and `rigor type-of` both expose: the `--tmp-file` /
    # `--instead-of` flag pair and the buffer-binding resolution that validates it. That resolution used to be copied
    # verbatim into both `Rigor::CLI` and `TypeOfCommand`, so a fix to one (the paired-flag check, the readability
    # check, the error wording) could silently miss the other. Centralising it keeps the two editor-mode entry points in
    # lockstep. It also owns the `--config` check (#1992), so every command and the MCP tools that pass `--config`
    # read the same rule.
    module Options
      module_function

      # Defines the standard `--config=PATH` flag on `parser`, writing the path into `options[:config]`. Used by every
      # subcommand that loads a `.rigor.yml`; the few whose `--config` help text is intentionally bespoke (`diff`,
      # `mcp`, `show-bleedingedge`) keep their own `parser.on` and call {.config_path} for the same check.
      def add_config(parser, options)
        parser.on("--config=PATH", "Path to the Rigor configuration file") do |value|
          options[:config] = config_path(value)
        end
      end

      # The `--config` value, checked where the flag is read (#1992). A named file that is not there is an error, not
      # a request for the defaults: the run would otherwise analyse under a configuration the caller did not ask for,
      # and an MCP caller would get a result for it with no sign anything was missing. Auto-discovery, with no
      # `--config` given, is not affected.
      def config_path(value)
        return value if File.exist?(value)

        raise ConfigurationError, "config file not found: #{value}"
      end

      # Defines the `--tmp-file` / `--instead-of` editor-mode flag pair on `parser`, writing into `options`.
      def add_editor_mode(parser, options)
        parser.on("--tmp-file=PATH",
                  "Editor mode: read source bytes from PATH instead of --instead-of (paired)") do |value|
          options[:tmp_file] = value
        end
        parser.on("--instead-of=PATH",
                  "Editor mode: the logical project path the buffer represents (paired with --tmp-file)") do |value|
          options[:instead_of] = value
        end
      end

      # Resolves the editor-mode buffer binding from parsed `options`: returns nil when neither editor-mode flag is set,
      # a `Analysis::BufferBinding` when the pair is valid, or `:usage_error` (after writing the reason to `err`) when
      # the flags are unpaired or the temp file is unreadable.
      def resolve_buffer_binding(options, err:)
        tmp = options[:tmp_file]
        instead = options[:instead_of]
        return nil if tmp.nil? && instead.nil?

        if tmp.nil? || instead.nil?
          err.puts("--tmp-file and --instead-of must appear together")
          return :usage_error
        end

        unless File.file?(tmp)
          err.puts("--tmp-file #{tmp.inspect}: no such file or not readable")
          return :usage_error
        end

        Analysis::BufferBinding.new(logical_path: instead, physical_path: tmp)
      end
    end
  end
end
