# frozen_string_literal: true

require_relative "command"

module Rigor
  class CLI
    # `rigor docs` — serve the documentation bundled with the
    # `rigortype` gem OFFLINE (ADR-74). The skills (`rigor skill <name>`)
    # already ride in the gem; this is the doc twin, so once Rigor is
    # installed an agent can read the guidance the SKILL-driven UX routes
    # to without the network. The canonical web copy is
    # rigor.typedduck.fail/llms.txt; the gem ships `docs/install.md`,
    # `docs/llms.txt`, and the full user-facing **manual** and
    # **handbook** (the drive-Rigor chapters — the contributor-facing
    # ADR / spec / notes corpus stays web-only).
    #
    # Grammar (mirrors `rigor skill`): the positional slot is always a
    # doc *name*; alternative outputs are flags, so a page named `list`
    # or `path` can never be shadowed by a verb.
    #
    # - `rigor docs`                  — print the bundled `llms.txt` index.
    # - `rigor docs <name>`           — print a doc page to stdout.
    # - `rigor docs --path <name>`    — one-line absolute path, for a Read tool.
    # - `rigor docs --list [<cat>]`   — table of name + path (optionally one category).
    #
    # `<name>` resolves a category-qualified path (`handbook/03-narrowing`),
    # a prefixed basename (`03-narrowing`), or a short name (`narrowing`,
    # when it is unique across categories).
    #
    # The pre-v0.3.0 verb spellings `rigor docs list` / `rigor docs path
    # <name>` still work but emit a stderr deprecation notice; they are
    # removed in v0.3.0 (see docs/ROADMAP.md § "Scheduled CLI
    # deprecations").
    class DocsCommand < Command
      USAGE = <<~USAGE
        Usage: rigor docs [<name>] [--path <name>] [--list [<category>]]

        With no argument, prints the bundled llms.txt offline doc index.

          rigor docs                      Print the offline doc index (llms.txt)
          rigor docs <name>               Print a doc page to stdout
          rigor docs --path <name>        Print the absolute path of a doc
          rigor docs --list [<category>]  List bundled docs (optionally one category)

        Categories: manual, handbook (plus the top-level install guide).
        A page is addressable by its category-qualified path
        (`handbook/03-narrowing`), its prefixed name (`03-narrowing`),
        or its short name (`narrowing`, when unique across categories).

        Examples:
          rigor docs
          rigor docs install
          rigor docs handbook/03-narrowing
          rigor docs editor-integration
          rigor docs --path 17-driving-improvement
          rigor docs --list handbook

        Deprecated (removed in v0.3.0) — use the flags above:
          rigor docs list           ->  rigor docs --list
          rigor docs path <name>    ->  rigor docs --path <name>
      USAGE

      # The bundled docs live at `<gem_root>/docs/`. From
      # `lib/rigor/cli/docs_command.rb` that is three directories up.
      DOCS_ROOT = File.expand_path("../../../docs", __dir__)
      MANUAL_ROOT = File.join(DOCS_ROOT, "manual")
      HANDBOOK_ROOT = File.join(DOCS_ROOT, "handbook")
      LLMS_INDEX = File.join(DOCS_ROOT, "llms.txt")

      # The verb subcommands the flags superseded keep working with a
      # stderr deprecation notice until this version drops them. Each maps
      # to the canonical advice printed and the flag it rewrites to.
      LEGACY_VERB_REMOVAL = "v0.3.0"
      LEGACY_VERBS = {
        "list" => { old: "list",        advice: "--list",        flag: "--list" },
        "path" => { old: "path <name>", advice: "--path <name>", flag: "--path" }
      }.freeze

      # @return [Integer] CLI exit status.
      def run
        rewrite_legacy_verb!

        case @argv.first
        when nil
          run_index
        when "-h", "--help", "help"
          @out.puts(USAGE)
          0
        when "--list"
          @argv.shift
          run_list(@argv.shift)
        when "--path"
          @argv.shift
          run_path(@argv.shift)
        when "--print"
          @argv.shift
          run_print(@argv.shift)
        else
          run_print(@argv.shift)
        end
      end

      private

      # Translate a deprecated verb spelling into its flag form, warning
      # once on stderr, so the dispatch above only handles canonical forms.
      def rewrite_legacy_verb!
        spec = LEGACY_VERBS[@argv.first]
        return unless spec

        @err.puts(
          "rigor docs: `#{spec.fetch(:old)}` is deprecated and will be removed in " \
          "#{LEGACY_VERB_REMOVAL}; use `rigor docs #{spec.fetch(:advice)}` instead."
        )
        @argv[0] = spec.fetch(:flag)
      end

      def run_index
        if File.file?(LLMS_INDEX)
          @out.write(File.read(LLMS_INDEX))
          0
        else
          run_list(nil)
        end
      end

      def run_list(category)
        docs = discover_docs
        if category
          categories = docs.map { |doc| doc.fetch(:category) }.uniq
          unless categories.include?(category)
            @err.puts("Unknown category: #{category}")
            @err.puts("Available categories: #{categories.join(', ')}")
            return 1
          end
          docs = docs.select { |doc| doc.fetch(:category) == category }
        end

        if docs.empty?
          @err.puts("No bundled docs found under #{DOCS_ROOT}")
          return 1
        end

        width = docs.map { |doc| doc.fetch(:relative).length }.max
        docs.each do |doc|
          @out.puts(format("%-#{width}s  %s", doc.fetch(:relative), doc.fetch(:path)))
        end
        0
      end

      def run_print(name)
        return usage_error("a doc name is required") if name.nil?

        doc = resolve_doc(name)
        return doc if doc.is_a?(Integer) # error status, already reported

        # ASCII-only provenance header: the doc body is read with the
        # external encoding (US-ASCII under a C locale), so a UTF-8 header
        # would set the output buffer to UTF-8 and clash with the body.
        @out.puts("<!-- rigor docs #{doc.fetch(:name)} (rigortype #{Rigor::VERSION}, offline) -->")
        @out.puts
        @out.write(File.read(doc.fetch(:path)))
        0
      end

      def run_path(name)
        return usage_error("`--path` requires a doc name") if name.nil?

        doc = resolve_doc(name)
        return doc if doc.is_a?(Integer)

        @out.puts(doc.fetch(:path))
        0
      end

      # Resolve a query to a single doc. Exact relative-path and
      # prefixed-basename aliases are unique; a short (prefix-stripped)
      # name is accepted only when one category owns it.
      #
      # @return [Hash, Integer] the doc entry, or an error exit status
      #   after the error has been written to `@err`.
      def resolve_doc(query)
        docs = discover_docs

        exact = docs.find { |doc| doc.fetch(:exact_aliases).include?(query) }
        return exact if exact

        short = docs.select { |doc| doc.fetch(:short_name) == query }
        case short.size
        when 1 then short.first
        when 0 then name_error(query)
        else ambiguous_error(query, short)
        end
      end

      # Every bundled doc, each carrying the aliases `rigor docs <name>`
      # accepts and the category used by `--list`. `install.md` sits at
      # the docs root (category `guide`); the rest are manual / handbook
      # chapters.
      def discover_docs
        paths = [File.join(DOCS_ROOT, "install.md")]
        paths += Dir.glob(File.join(MANUAL_ROOT, "**", "*.md")) # Dir.glob is already sorted
        paths += Dir.glob(File.join(HANDBOOK_ROOT, "**", "*.md"))
        paths.select { |path| File.file?(path) }.map { |path| doc_entry(path) }
      end

      def doc_entry(path)
        relative = path.delete_prefix("#{DOCS_ROOT}/").delete_suffix(".md")
        base = File.basename(path, ".md")
        short = base.sub(/\A\d+-/, "")
        segments = relative.split("/")
        category = segments.size > 1 ? segments.first : "guide"
        {
          name: base,
          relative: relative,
          path: path,
          category: category,
          # Always-unique addresses: the `docs/`-relative path and the
          # prefixed basename. `handbook/03-narrowing` and `03-narrowing`.
          exact_aliases: [relative, base].uniq,
          # The prefix-stripped short name (`narrowing`); ambiguous when
          # two categories carry the same chapter slug (`plugins`).
          short_name: short
        }
      end

      def name_error(name)
        @err.puts("Unknown doc: #{name}")
        @err.puts("Available docs (try `rigor docs --list`):")
        discover_docs.each { |doc| @err.puts("  #{doc.fetch(:relative)}") }
        1
      end

      def ambiguous_error(query, candidates)
        @err.puts("Ambiguous doc name: #{query}")
        @err.puts("Matches several docs — qualify with the category path:")
        candidates.each { |doc| @err.puts("  #{doc.fetch(:relative)}") }
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
