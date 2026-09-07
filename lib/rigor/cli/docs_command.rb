# frozen_string_literal: true

require_relative "command"
require_relative "doc_links"

module Rigor
  class CLI
    # `rigor docs` — serve the documentation bundled with the `rigortype` gem OFFLINE (ADR-74). The skills (`rigor skill
    # <name>`) already ride in the gem; this is the doc twin, so once Rigor is installed an agent can read the guidance
    # the SKILL-driven UX routes to without the network. The canonical web copy is rigor.typedduck.fail/llms.txt; the
    # gem ships `docs/install.md`, `docs/llms.txt`, and the full user-facing **manual** and **handbook** (the
    # drive-Rigor chapters — the contributor-facing ADR / spec / notes corpus stays web-only).
    #
    # Grammar (mirrors `rigor skill`): the positional slot is always a doc *name*; alternative outputs are flags, so a
    # page named `list` or `path` can never be shadowed by a verb.
    #
    # - `rigor docs`                  — print the bundled `llms.txt` index.
    # - `rigor docs <name>`           — print a doc page to stdout.
    # - `rigor docs --path <name>`    — one-line absolute path, for a Read tool.
    # - `rigor docs --list [<cat>]`   — table of name + path (optionally one category).
    #
    # `<name>` resolves a category-qualified path (`handbook/03-narrowing`), a prefixed basename (`03-narrowing`), or a
    # short name (`narrowing`, when it is unique across categories).
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
      USAGE

      # The bundled docs live at `<gem_root>/docs/`. From `lib/rigor/cli/docs_command.rb` that is three directories up.
      DOCS_ROOT = File.expand_path("../../../docs", __dir__)
      MANUAL_ROOT = File.join(DOCS_ROOT, "manual")
      HANDBOOK_ROOT = File.join(DOCS_ROOT, "handbook")
      LLMS_INDEX = File.join(DOCS_ROOT, "llms.txt")

      # @rbs return: Integer -- CLI exit status.
      def run
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

        # ASCII-only provenance header: the doc body is read with the external encoding (US-ASCII under a C locale), so
        # a UTF-8 header would set the output buffer to UTF-8 and clash with the body.
        @out.puts("<!-- rigor docs #{doc.fetch(:name)} (rigortype #{Rigor::VERSION}, offline) -->")
        @out.puts
        @out.write(DocLinks.rewrite(File.read(doc.fetch(:path)), from: doc.fetch(:path)))
        0
      end

      def run_path(name)
        return usage_error("`--path` requires a doc name") if name.nil?

        doc = resolve_doc(name)
        return doc if doc.is_a?(Integer)

        @out.puts(doc.fetch(:path))
        0
      end

      # Resolve a query to a single doc. Exact relative-path and prefixed-basename aliases are unique; a short
      # (prefix-stripped) name is accepted only when one category owns it.
      #
      # @rbs return: Hash[untyped, untyped] | Integer --
      #   The doc entry, or an error exit status after the error has been written to `@err`.
      def resolve_doc(query)
        # A key printed by a rendered page may carry the section it pointed at; resolve the page and say
        # where to look inside it, rather than refusing a key this command handed out.
        query, anchor = DocLinks.split_anchor(query)
        @err.puts("rigor: (section `#{anchor}`)") if anchor && !anchor.empty?
        docs = discover_docs

        exact = docs.find { |doc| doc.fetch(:exact_aliases).include?(query) }
        return exact if exact

        short = docs.select { |doc| doc.fetch(:short_name) == query }
        case short.size
        when 1 then short.first
        when 0 then unpackaged_doc(query) || name_error(query)
        else ambiguous_error(query, short)
        end
      end

      # A key the rendered pages hand out for a document the gem does not carry (ADR-74 ships the manual and
      # handbook; the ADR / specification / notes corpus and the repository trees stay out). The key is
      # still answerable — it names a real path — so this routes rather than failing: a reader who followed
      # `[ADR-103][adr/103-effect-labels]` out of `rigor docs` gets told where that document is, which is the
      # whole point of handing them the key instead of a dead relative path or a `master` URL.
      # Categories this command serves itself. A name that fails to resolve inside one of them is a typo,
      # not an unpackaged document, and must reach the did-you-mean listing rather than be routed to a
      # repository path that does not exist — `rigor docs list` and `rigor docs pathh` are the cases
      # that found this.
      PACKAGED_CATEGORIES = %w[manual handbook].freeze
      private_constant :PACKAGED_CATEGORIES

      def unpackaged_doc(query)
        return nil unless query.include?("/")
        return nil if PACKAGED_CATEGORIES.include?(query.split("/").first)

        path = DocLinks.repository_path(query)
        return nil if path.nil?

        @err.puts("rigor: `#{query}` is not packaged with this gem — the manual and handbook are, the " \
                  "design records are not.")
        @err.puts("rigor: it is `#{path}` in the Rigor repository (#{DocLinks::REPOSITORY}).")
        1
      end

      # Every bundled doc, each carrying the aliases `rigor docs <name>` accepts and the category used by `--list`.
      # `install.md` sits at the docs root (category `guide`); the rest are manual / handbook chapters.
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
          # Always-unique addresses: the `docs/`-relative path and the prefixed basename. `handbook/03-narrowing` and
          # `03-narrowing`.
          exact_aliases: [relative, base].uniq,
          # The prefix-stripped short name (`narrowing`); ambiguous when two categories carry the same chapter slug
          # (`plugins`).
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
