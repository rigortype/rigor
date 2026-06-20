# frozen_string_literal: true

require_relative "command"

module Rigor
  class CLI
    # `rigor docs` — serve the manual bundled with the `rigortype` gem
    # OFFLINE (ADR-74). The skills (`rigor skill print`) already ride in
    # the gem; this is the doc twin, so once Rigor is installed an agent
    # can read the guidance the SKILL-driven UX routes to without the
    # network. The canonical web copy is rigor.typedduck.fail/llms.txt;
    # the gem ships `docs/install.md`, `docs/llms.txt`, and the full
    # `docs/manual/` (the drive-Rigor chapters — the contributor-facing
    # ADR / spec / notes corpus stays web-only).
    #
    # Subcommands (mirroring `rigor skill`):
    #
    # - `rigor docs`            — print the bundled `llms.txt` index.
    # - `rigor docs <name>`     — print a manual page (`install`,
    #                             `02-cli-reference`, `cli-reference`,
    #                             `17-driving-improvement`, …) to stdout.
    # - `rigor docs list`       — table of name + absolute path.
    # - `rigor docs path <name>`— one-line absolute path, for a Read tool.
    class DocsCommand < Command
      USAGE = <<~USAGE
        Usage: rigor docs [<name> | list | path <name>]

        With no argument, prints the bundled llms.txt doc index.

          rigor docs                     Print the offline doc index (llms.txt)
          rigor docs <name>              Print a manual page to stdout
          rigor docs list                List every bundled doc (name + path)
          rigor docs path <name>         Print the absolute path of a doc

        Examples:
          rigor docs
          rigor docs install
          rigor docs editor-integration
          rigor docs path 17-driving-improvement
      USAGE

      # The bundled docs live at `<gem_root>/docs/`. From
      # `lib/rigor/cli/docs_command.rb` that is three directories up.
      DOCS_ROOT = File.expand_path("../../../docs", __dir__)
      MANUAL_ROOT = File.join(DOCS_ROOT, "manual")
      LLMS_INDEX = File.join(DOCS_ROOT, "llms.txt")

      # @return [Integer] CLI exit status.
      def run
        subcommand = @argv.shift

        case subcommand
        when nil then run_index
        when "list" then run_list
        when "path" then run_path
        when "-h", "--help", "help"
          @out.puts(USAGE)
          0
        else
          run_print(subcommand)
        end
      end

      private

      def run_index
        if File.file?(LLMS_INDEX)
          @out.write(File.read(LLMS_INDEX))
          0
        else
          run_list
        end
      end

      def run_list
        docs = discover_docs
        if docs.empty?
          @err.puts("No bundled docs found under #{DOCS_ROOT}")
          return 1
        end

        width = docs.map { |d| d.fetch(:name).length }.max
        docs.each do |doc|
          @out.puts(format("%-#{width}s  %s", doc.fetch(:name), doc.fetch(:path)))
        end
        0
      end

      def run_print(name)
        doc = find_doc(name)
        return name_error(name) if doc.nil?

        # ASCII-only provenance header: the doc body is read with the
        # external encoding (US-ASCII under a C locale), so a UTF-8 header
        # would set the output buffer to UTF-8 and clash with the body.
        @out.puts("<!-- rigor docs #{doc.fetch(:name)} (rigortype #{Rigor::VERSION}, offline) -->")
        @out.puts
        @out.write(File.read(doc.fetch(:path)))
        0
      end

      def run_path
        name = @argv.shift
        return usage_error("`path` requires a doc name") if name.nil?

        doc = find_doc(name)
        return name_error(name) if doc.nil?

        @out.puts(doc.fetch(:path))
        0
      end

      # Every bundled doc, each addressable by its short name (basename
      # without the `.md` and numeric prefix), its prefixed basename, and
      # its `docs/`-relative path. `install.md` sits at the docs root; the
      # rest are manual chapters / plugin pages.
      def discover_docs
        paths = [File.join(DOCS_ROOT, "install.md")]
        paths += Dir.glob(File.join(MANUAL_ROOT, "**", "*.md")) # Dir.glob is already sorted
        existing = paths.select { |path| File.file?(path) }
        existing.map { |path| { name: primary_name(path), path: path, aliases: doc_aliases(path) } }
      end

      def find_doc(query)
        discover_docs.find { |doc| doc.fetch(:aliases).include?(query) }
      end

      # `02-cli-reference.md` → primary display name `02-cli-reference`.
      def primary_name(path)
        File.basename(path, ".md")
      end

      # Every string `rigor docs <name>` accepts for this file:
      # `manual/02-cli-reference`, `02-cli-reference`, `cli-reference`.
      def doc_aliases(path)
        relative = path.delete_prefix("#{DOCS_ROOT}/").delete_suffix(".md")
        base = File.basename(path, ".md")
        stripped = base.sub(/\A\d+-/, "")
        [relative, base, stripped].uniq
      end

      def name_error(name)
        @err.puts("Unknown doc: #{name}")
        @err.puts("Available docs (try `rigor docs list`):")
        discover_docs.each { |doc| @err.puts("  #{doc.fetch(:name)}") }
        1
      end

      def usage_error(message)
        @err.puts(message)
        @err.puts(USAGE)
        Rigor::CLI::EXIT_USAGE
      end
    end
  end
end
