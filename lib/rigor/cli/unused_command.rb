# frozen_string_literal: true

require "optionparser"
require "json"

require_relative "../configuration"
require_relative "../analysis/path_expansion"
require_relative "../analysis/reachability/scan"
require_relative "../analysis/reachability/graph"
require_relative "../analysis/reachability/plugin_roots"
require_relative "options"
require_relative "command"
require_relative "probe_environment"

module Rigor
  class CLI
    # ADR-102 — executes `rigor unused`.
    #
    # Reports project constants that nothing reachable references. It is a REPORT, never a diagnostic: the
    # measured precision of this signal is 7.0% on an adjudicated corpus target
    # (`docs/notes/20260813-unused-constant-fp-baseline.md`), so its output is a review queue, not a defect
    # list, and it never enters `rigor check`'s stream at any severity (WD1). Exits 0 whatever it finds.
    class UnusedCommand < Command
      USAGE = "Usage: rigor unused [options] [paths]"

      # WD7 — the REFERENCE corpus is wider than the ANALYSIS corpus. `.rake` files sit inside `paths:` and
      # reference project constants, but `PathExpansion::RUBY_GLOB` never reads them, which made them pure
      # artifacts on two of three corpus targets. Harvesting references from a file is far cheaper than
      # type-checking it, so the report takes the wider set.
      REFERENCE_GLOB = "**/*.{rb,rake}"

      # Trees that are never the project's own source. Globbing them costs far more than every analysed file
      # combined on a real app, and a reference found inside a vendored gem is not evidence about this project.
      VENDOR_DIRS = %r{\A(vendor|node_modules|tmp|\.git|\.rigor|coverage)/}

      # Templates and data files that carry class names as strings. A name here is NOT counted as a reference —
      # a YAML value is far weaker evidence than a constant node, and treating it as proof would silently hide
      # real dead code. It demotes the declaration to `cannot-decide` instead, with the file named, so the
      # reader judges it (ADR-102 WD4).
      TEMPLATE_GLOB = "**/*.{erb,haml,slim,yml,yaml,json}"

      def run
        options = parse_options
        return CLI::EXIT_USAGE if options == :usage_error

        configuration = Configuration.load(options.fetch(:config))
        paths = @argv.empty? ? configuration.paths : @argv
        declarations, references, dynamic_uses = scan(paths, configuration)
        references.concat(signature_references(configuration))
        dynamic_uses.concat(template_mentions(declarations))

        plugin_roots = Analysis::Reachability::PluginRoots.collect(configuration: configuration)
        graph = Analysis::Reachability::Graph.new(
          declarations: declarations, references: references, dynamic_uses: dynamic_uses,
          root_fqns: root_fqns(declarations, options.fetch(:entry_points)) + plugin_roots,
          foreign: foreign_predicate(configuration)
        )
        emit(graph.report, options, supply: root_supply(plugin_roots, declarations))
        0
      end

      private

      def parse_options
        options = { config: nil, format: "text", entry_points: [], limit: nil }
        parser = OptionParser.new do |opts|
          opts.banner = USAGE
          Options.add_config(opts, options)
          opts.on("--format=FORMAT", "Output format: text (default) or json") { |v| options[:format] = v }
          opts.on("--entry-point=GLOB", "Treat declarations in files matching GLOB as roots (repeatable)") do |v|
            options[:entry_points] << v
          end
          opts.on("--limit=N", Integer, "Print at most N candidates (default: all)") { |v| options[:limit] = v }
          # WD5 — refuse rather than silently absorb. A reachability answer is sound only over a full run, and a
          # user who asked for the fast path must not silently get the slow one.
          opts.on("--incremental", "(unsupported)") { options[:incremental] = true }
        end
        parser.parse!(@argv)
        return usage_error(parser) if options[:incremental]

        options
      rescue OptionParser::ParseError => e
        @err.puts(e.message)
        :usage_error
      end

      def usage_error(_parser)
        @err.puts("rigor unused does not support --incremental: reachability is only sound over a whole-project " \
                  "run, so an incremental pass would report constants as unused merely because the files that " \
                  "reference them were served from cache. Re-run without --incremental.")
        :usage_error
      end

      # Declarations come from the analysed paths; references additionally from the wider corpus (WD7).
      def scan(paths, configuration)
        declaration_files = Analysis::PathExpansion.ruby_files(paths, configuration.exclude_patterns).to_set
        declarations = []
        references = []
        dynamic_uses = []
        (declaration_files + reference_files(paths, configuration)).sort.each do |file|
          result = read_and_scan(file, configuration)
          next if result.nil?

          declarations.concat(result.declarations) if declaration_files.include?(file)
          references.concat(result.references)
          dynamic_uses.concat(result.dynamic_uses)
        end
        [declarations, references, dynamic_uses]
      end

      # The reference corpus is the PROJECT, not the analysed paths. A constant declared in `lib/` is commonly
      # referenced from `config/initializers`, a `.rake` task, or a spec — none of which are in `paths:` — and
      # treating those as absent is what manufactured artifacts on two of three corpus targets in #345.
      # Widening the *declaration* set the same way would cancel the gain (measured: +1 / −3 / +2 candidates,
      # ADR-102 WD2), which is exactly why the two corpora are separated rather than both widened.
      def reference_files(_paths, configuration)
        relative = Dir.glob(REFERENCE_GLOB, base: Dir.pwd).grep_v(VENDOR_DIRS)
        absolute = relative.map { |rel| File.expand_path(rel) }
        Analysis::PathExpansion.reject_excluded(absolute, configuration.exclude_patterns).to_set
      end

      def read_and_scan(file, configuration)
        Analysis::Reachability::Scan.call(path: file, source: File.read(file),
                                          target_ruby: configuration.target_ruby)
      rescue SystemCallError
        nil
      end

      # A glob is matched against the declaration's path AND its path relative to the working directory:
      # `configuration.paths` are expanded to absolute, so a user-written `--entry-point=lib/entry.rb` would
      # otherwise never match anything and silently produce a root set of zero.
      # A constant named only from the project's own `sig/` is referenced — the #345 probe reported exactly this
      # as a false candidate until an RBS-side hook was added, because `Reflection.resolve_constant_type` is
      # source-side only.
      #
      # Harvested by scanning each signature for constant-shaped tokens rather than by walking the parsed RBS
      # AST. That deliberately OVER-approximates (a name inside a comment counts), and over-approximating
      # references is the false-positive-safe direction for this report: it can only remove candidates, never
      # invent one. Every such reference is attributed at file level with the `:config` role, so it seeds
      # production reachability but is not mistaken for test usage.
      CONSTANT_TOKEN = /\b[A-Z][A-Za-z0-9_]*(?:::[A-Z][A-Za-z0-9_]*)*/
      private_constant :CONSTANT_TOKEN

      def signature_references(configuration)
        Array(configuration.signature_paths).flat_map do |dir|
          next [] unless File.directory?(dir)

          Dir.glob(File.join(dir, "**/*.rbs")).flat_map do |file|
            File.read(file).scan(CONSTANT_TOKEN).map do |name|
              Analysis::Reachability::Scan::Reference.new(as_written: name, nesting: [].freeze, from: nil,
                                                          role: :config, path: file, line: 1)
            end
          rescue SystemCallError
            []
          end
        end
      end

      def template_mentions(declarations)
        names = declarations.map(&:fqn)
        return [] if names.empty?

        Dir.glob(TEMPLATE_GLOB, base: Dir.pwd).grep_v(VENDOR_DIRS).flat_map do |rel|
          text = File.read(File.expand_path(rel))
          names.filter_map do |fqn|
            next unless text.include?(fqn)

            Analysis::Reachability::Scan::DynamicUse.new(name: nil, prefix: fqn, site: nil,
                                                         reason: "named as a string in #{rel}",
                                                         path: rel, line: 1)
          end
        rescue SystemCallError, ArgumentError
          []
        end
      end

      def root_fqns(declarations, globs)
        return [] if globs.empty?

        cwd = "#{File.expand_path(Dir.pwd)}/"
        declarations.filter_map do |d|
          relative = d.path.delete_prefix(cwd)
          d.fqn if globs.any? { |g| File.fnmatch?(g, d.path) || File.fnmatch?(g, relative) }
        end
      end

      # WD6 — ownership means "declared FIRST here". Reopening a gem or stdlib class registers it as a project
      # declaration, which produced three of redmine's artifacts from a single initializer. A name the bundled
      # (non-project) environment already knows is not ours to call unused. The project's own `sig/` is
      # deliberately excluded from this environment, so a project class that ships a signature stays owned.
      def foreign_predicate(configuration)
        env = Environment.for_project(libraries: configuration.libraries, signature_paths: [])
        ->(fqn) { !env.singleton_for_name(fqn).nil? }
      rescue StandardError
        ->(_fqn) { false }
      end

      # ADR-102 § Consequences — "a root source that OVER-supplies silently hides real dead code, which is
      # worse than one that under-supplies, so each plugin's contribution needs its own corpus check". A
      # supplied root naming a constant the project does not declare is inert in the graph, but it is the
      # observable symptom of a root source drifting away from the code — a renamed controller, an
      # inflection the plugin gets wrong, a convention that stopped holding. Reporting the count makes that
      # drift measurable on a real project instead of invisible.
      Supply = Data.define(:supplied, :unmatched)
      private_constant :Supply

      def root_supply(plugin_roots, declarations)
        declared = declarations.to_set(&:fqn)
        Supply.new(supplied: plugin_roots.size, unmatched: plugin_roots.count { |fqn| !declared.include?(fqn) })
      end

      def emit(report, options, supply:)
        @out.puts(options.fetch(:format) == "json" ? json(report, options, supply) : text(report, options, supply))
      end

      def json(report, options, supply)
        JSON.pretty_generate(
          declared: report.declared, reachable: report.reachable, roots: report.roots, edges: report.edges,
          namespaces: report.namespaces,
          plugin_roots: supply.supplied, plugin_roots_unmatched: supply.unmatched,
          candidates: rows_json(report.candidates, options), test_only: rows_json(report.test_only, options),
          undecidable: limited(report.undecidable, options).map do |u|
            { name: u.fqn, path: u.path, line: u.line, reason: u.reason }
          end
        )
      end

      def rows_json(rows, options)
        limited(rows, options).map { |c| { name: c.fqn, path: c.path, line: c.line } }
      end

      def text(report, options, supply)
        lines = ["Reachability", "  declared (project-owned): #{report.declared}",
                 "  roots:                    #{report.roots}#{plugin_root_note(supply)}",
                 "  reachable:                #{report.reachable}",
                 "  candidates:               #{report.candidates.size}",
                 "  reachable only from tests: #{report.test_only.size}",
                 "  cannot decide:            #{report.undecidable.size}",
                 "  namespace-only (excluded):  #{report.namespaces}"]
        lines.concat(section("Candidates — nothing reachable references these", report.candidates, options))
        lines.concat(section("Reachable only from test code — live test, dead production path",
                             report.test_only, options))
        lines.concat(undecidable_section(report.undecidable, options))
        lines << ""
        lines << "These are CANDIDATES, not findings. The measured precision of this report on an adjudicated"
        lines << "corpus target is 7% — every row needs a human to confirm it. Roots a framework supplies come"
        lines << "from the project's plugins, so a framework Rigor has no plugin for still reads as an upper bound."
        lines.join("\n")
      end

      # `(N from plugins, M matched nothing)` — omitted entirely when no plugin contributed, so a
      # non-Rails project's report is unchanged. A non-zero `matched nothing` is the over-supply signal
      # described on {#root_supply}: those roots claim constants this project does not declare.
      def plugin_root_note(supply)
        return "" if supply.supplied.zero?

        " (#{supply.supplied} from plugins, #{supply.unmatched} matched no declaration)"
      end

      def undecidable_section(rows, options)
        return [] if rows.empty?

        out = ["", "Cannot decide — something can name these at runtime (#{rows.size})"]
        limited(rows, options).each_with_index do |u, i|
          out << format("  %<n>3d  %<name>-52s %<path>s:%<line>d", n: i + 1, name: u.fqn, path: u.path,
                                                                   line: u.line)
          out << "       #{u.reason}"
        end
        out
      end

      def section(title, rows, options)
        return [] if rows.empty?

        out = ["", "#{title} (#{rows.size})"]
        limited(rows, options).each_with_index do |c, i|
          out << format("  %<n>3d  %<name>-52s %<path>s:%<line>d", n: i + 1, name: c.fqn, path: c.path, line: c.line)
        end
        out
      end

      def limited(candidates, options)
        limit = options.fetch(:limit)
        limit ? candidates.first(limit) : candidates
      end
    end
  end
end
