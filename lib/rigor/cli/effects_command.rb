# frozen_string_literal: true

require "optionparser"

require_relative "../configuration"
# ADR-104 — `analysis/runner` is required lazily (in `#analyze`), not here: a warm report served by
# {Analysis::EffectsCacheProbe} must reach its answer without `rigor/inference` in `$LOADED_FEATURES`,
# which is the whole of the boot saving. The probe pulls only the cache and the effects value layer.
require_relative "../analysis/effects_cache_probe"
require_relative "../effects/plugin_facts"
require_relative "../effects/registry"
require_relative "../plugin/loader"
require_relative "../cache/store"
require_relative "command"
require_relative "effects_renderer"
require_relative "effects_report"
require_relative "effects_snapshot_command"
require_relative "options"

module Rigor
  class CLI
    # ADR-103 — executes `rigor effects`.
    #
    # Two surfaces behind one command, the shape `rigor baseline` already has:
    #
    # - `rigor effects [PATH…]` — the **report**. Runs the same analysis `rigor check` runs, with effect
    #   collection on, and prints the resulting summaries instead of the diagnostic stream.
    # - `rigor effects {update,check,diff,explain}` — the committed **effect snapshot** and its drift
    #   gate, in {EffectsSnapshotCommand}.
    #
    # Neither emits a diagnostic nor enters `rigor check`'s stream; the report always exits 0, and only
    # `check` ever exits non-zero (1 on drift, 64 on a usage error).
    #
    # The command turns collection on for its own run by loading the project's configuration and enabling
    # an implicit `effects: {}` when the file carries no `effects:` block — the ad-hoc mode ADR-103 WD14
    # describes. A project that *does* configure `effects:` gets its own settings instead, and then this
    # run shares the whole cache with `rigor check`: the diagnostics come from the ADR-45 run entry and the
    # summaries from the effects sidecar keyed beside it (#382), so `rigor effects` after `rigor check` in
    # the same job is a warm hit plus the fixpoint. The ad-hoc mode digests a different `effects:` block
    # than the project's, so it shares the diagnostics entry and keys its own effects slot.
    class EffectsCommand < Command
      USAGE = "Usage: rigor effects [options] [paths]"

      # @return [Integer] CLI exit status: 0 on success, 1 on `check` drift, 64 on a usage error.
      def run
        verb = @argv.first
        return run_verb(verb) if EffectsSnapshotCommand::VERBS.include?(verb)
        return print_help if %w[help --help -h].include?(verb)

        run_report
      end

      private

      def run_verb(verb)
        @argv.shift
        EffectsSnapshotCommand.new(argv: @argv, verb: verb, out: @out, err: @err).run
      end

      def print_help
        @out.puts(help)
        0
      end

      def help
        <<~HELP
          #{USAGE}

          With no subcommand, prints one line per method: its proven effect labels and whether that
          list is exhaustive. A PATH selects which methods are printed, never which are analysed.

          Options:
            --config=PATH        Path to the Rigor configuration file
            --format=FORMAT      Output format: text (default) or json
            --full               List every method, including the ones with nothing to say
            --label=LABEL        Only methods carrying LABEL (or a label under it), in either lane
            --pure               Only methods proven to do nothing beyond mutate.local
            --limit=N            Print at most N methods
            --why                Expand each method's unresolved reasons and declared-lane sources
            --list-labels        Print the effect vocabulary this project can name, and exit

          Subcommands (the committed effect snapshot, ADR-103 WD7):
            update      Write the snapshot to effects.snapshot.path. Commit it; review its diff.
            check       Recompute and compare; exits 1 on drift, 0 when fresh.
            diff        The same comparison, never gating.
            explain     The shortest edge path behind a reach change (--symbol KEY for one unit).

          Run `rigor effects <subcommand> --help` for subcommand options.
        HELP
      end

      def run_report
        options = parse_options
        return usage_error("unsupported format: #{options.fetch(:format)}") unless FORMATS.include?(options[:format])

        configuration = Configuration.load(options.fetch(:config)).with_effects_enabled
        return list_labels(configuration) if options.fetch(:list_labels)

        scope = @argv.dup
        table, sources = resolve_table(configuration, scope)
        report = EffectsReport.build(
          table, full: options.fetch(:full), sources: sources, scope: scope,
                 label: options.fetch(:label), pure: options.fetch(:pure), limit: options.fetch(:limit)
        )
        note_scope(scope, report, table)
        EffectsRenderer.new(out: @out, why: options.fetch(:why)).render(report, format: options.fetch(:format))
        0
      end

      # A path argument is a **view**, and the note says so (#439).
      #
      # It used to narrow the analysed set, and effect labels are transitive over whatever was analysed —
      # so `rigor effects app/controllers/issues_controller.rb` reported `IssuesController#create: [] …?`
      # where the whole-project run reported four labels and a declared lane. The weakened answer was
      # indistinguishable from a genuinely effect-free method, and a path argument is the only tractability
      # lever the report has, so it was the thing an adopter reached for first.
      #
      # The note goes to stderr rather than into the report: it is about the invocation, not about the
      # code, and `--format json` and `rigor effects … > report.txt` both stay exactly what they were.
      def note_scope(scope, report, table)
        return if scope.empty?

        if report.empty?
          @err.puts("rigor: no effect unit is defined in #{scope.join(', ')} " \
                    "(a path selects what is printed, not what is analysed)")
          return
        end

        @err.puts("rigor: showing #{report.rows.length} of #{table.size} units, selected by " \
                  "#{scope.join(', ')}; a path narrows the printing and not the analysis, so every " \
                  "label is the one the whole-project run reports")
      end

      FORMATS = %w[text json].freeze
      private_constant :FORMATS

      def parse_options
        options = { config: nil, format: "text", full: false, no_tolerated: false, label: [], pure: false,
                    limit: nil, why: false, list_labels: false }
        OptionParser.new do |opts|
          opts.banner = USAGE
          Options.add_config(opts, options)
          opts.on("--format=FORMAT", "Output format: text (default) or json") { |value| options[:format] = value }
          opts.on("--full", "List every method, including the ones with nothing to say") do
            options[:full] = true
          end
          opts.on("--label=LABEL", "Only methods carrying LABEL (or a label under it), in either lane") do |value|
            options[:label].concat(value.split(",").map(&:strip).reject(&:empty?))
          end
          opts.on("--pure", "Only methods proven to do nothing beyond mutate.local — the %a{pure} set") do
            options[:pure] = true
          end
          opts.on("--limit=N", Integer, "Print at most N methods") { |value| options[:limit] = value }
          opts.on("--why", "Expand each method's unresolved reasons and declared-lane sources") do
            options[:why] = true
          end
          opts.on("--list-labels", "Print the effect vocabulary this project can name, and exit") do
            options[:list_labels] = true
          end
          # Accepted here and deliberately inert, exactly as it is on `update`: the report is an
          # observation, and observations are undischarged. Only a JUDGMENT reads `effects.tolerated:` —
          # `rigor effects check` / `diff`, and `rigor check`'s envelope contract.
          opts.on("--no-tolerated-effects", "Judge as if effects.tolerated: were empty (inert on the report)") do
            options[:no_tolerated] = true
          end
        end.parse!(@argv)
        options
      end

      def usage_error(message)
        @err.puts(message)
        @err.puts(USAGE)
        CLI::EXIT_USAGE
      end

      # Sequential and cache-backed, through the same ADR-45 whole-run result cache `rigor check` uses:
      # the diagnostics entry serves the run and the #382 effects sidecar serves the collections, leaving
      # only the fixpoint. Sequential is not a cache decision — the run-result cache declines pool mode —
      # but a collecting run is pinned to the fork backend anyway, so `workers: 0` costs nothing here.
      # #429 — the vocabulary, from the product rather than from a document the gem does not ship.
      #
      # Four configuration keys and two annotation forms all require typing an effect label, and until
      # this there was no way to find out what the labels are: the manual's pointers resolve into
      # `docs/type-specification/`, which `rigortype.gemspec` does not package. The registry is shipped
      # data and already knows the answer; nothing surfaced it.
      #
      # It loads plugins but never analyses, because a plugin is where `rails.flash.write` comes from and
      # a reader deciding what to write in `effects.envelopes:` needs to see it. A plugin that fails to
      # load costs its labels and nothing else — `rigor plugins` is where that failure is reported.
      def list_labels(configuration)
        registry = project_registry(configuration)
        @out.puts("Effect vocabulary — #{registry.labels.length} labels (vocabulary #{registry.vocabulary_version})")
        registry.roots.each do |root|
          @out.puts
          @out.puts(root_heading(root, registry))
          in_root = registry.labels.select { |label| Effects::Label.root(label) == root }
          in_root.each_slice(4) { |slice| @out.puts("  #{slice.join(', ')}") }
        end
        @out.puts
        @out.puts("A bound naming a label admits everything under it and nothing above it: `io` covers " \
                  "`io.db.read`, `io.db.read` does not cover `io`.")
        0
      end

      # A shipped root carries the registry's own one-liner; a root a plugin or this project opened
      # carries where it came from instead, which is the more useful thing to say about it.
      def root_heading(root, registry)
        description = registry.descriptions[root]
        return "#{root} — #{description}" if description

        "#{root} — opened by a plugin or by this project's `effects.labels:`"
      end

      def project_registry(configuration)
        services = Plugin::Services.new(reflection: Reflection, type: Type::Combinator,
                                        configuration: configuration, cache_store: nil)
        plugins = Plugin::Loader.load(configuration: configuration, services: services)
        Effects::Registry.for_configuration(configuration, plugin_facts: Effects::PluginFacts.build(plugins))
      rescue StandardError
        Effects::Registry.for_configuration(configuration)
      end

      # The analysed set is the configured `paths:` **plus** whatever the arguments name — never the
      # arguments alone (#439). An effect summary is transitive over whatever was analysed, so analysing
      # less does not filter the report, it lowers every answer in it: `rigor effects
      # app/controllers/issues_controller.rb` used to report `IssuesController#create: [] …?` where the
      # whole-project run reported four labels and a declared lane, with nothing marking the difference.
      #
      # The union rather than the configured paths alone, so that pointing the command at a tree the
      # configuration does not cover — which is what every `rigor effects PATH` invocation from outside a
      # project does — still analyses it. Inside a project the argument is already under `paths:` and the
      # union is the configured set unchanged.
      #
      # @return [Array(Rigor::Effects::EffectTable, Hash{String=>Array<String>})] the table, and which
      #   file each unit was defined in — the map {EffectsReport} needs to answer a path argument.
      def analyze(configuration, scope)
        require_relative "../analysis/runner"
        runner = Analysis::Runner.new(
          configuration: configuration,
          cache_store: Cache::Store.new(root: configuration.cache_path),
          collect_stats: false,
          workers: 0
        )
        runner.run((configuration.paths + scope).uniq)
        [runner.effect_table, runner.effect_sources]
      end

      # ADR-104 — the report before the engine. A warm run's whole answer is the #482 summary entry, so
      # {Analysis::EffectsCacheProbe} tries to serve it without loading `rigor/inference`; any decline
      # falls through to the full runner, which behaves exactly as it did.
      #
      # The report is a pure function of the table, the sources and the configuration: the envelope
      # diagnostics the analysing path also computes are discarded here (this method reads the table
      # and the sources and nothing else), which is what makes the served answer identical rather than
      # merely similar.
      def resolve_table(configuration, scope)
        served = probe(configuration, scope)
        return [served.table, served.sources] if served

        analyze(configuration, scope)
      end

      def probe(configuration, scope)
        Analysis::EffectsCacheProbe.new(
          configuration: configuration, cache_root: configuration.cache_path
        ).serve((configuration.paths + scope).uniq)
      end
    end
  end
end
