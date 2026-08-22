# frozen_string_literal: true

require "optionparser"

require_relative "../analysis/runner"
require_relative "../cache/store"
require_relative "../configuration"
require_relative "../effects/discharge"
require_relative "../effects/entry_points"
require_relative "../effects/path_finder"
require_relative "../effects/snapshot"
require_relative "../effects/snapshot_diff"
require_relative "command"
require_relative "effects_diff_renderer"
require_relative "effects_explain_renderer"
require_relative "options"

module Rigor
  class CLI
    # ADR-103 WD7 — the snapshot verbs of `rigor effects`: `update`, `check`, `diff` and `explain`.
    #
    #   rigor effects update                  # write .rigor-effects.yml; commit it
    #   rigor effects check                   # 0 fresh, 1 drift — the CI gate
    #   rigor effects diff --baseline PATH    # the same comparison, never gating
    #   rigor effects explain --symbol KEY    # the shortest edge path behind a reach change
    #
    # None of them emits a diagnostic or enters `rigor check`'s stream: drift between two observations by
    # the same tool is 100 % precise, and whether it *matters* is the reviewer's judgment — which is
    # exactly what makes it a review artefact rather than a finding
    # ([ADR-102](../adr/102-unused-code-reachability-report.md)).
    #
    # **The verbs take no paths.** The report does (`rigor effects lib/foo.rb`), because a report is a
    # view; a snapshot is a record of the whole project, and one written over a subset would read as a
    # project where every other method vanished. The analysed set is always the configured `paths:`.
    class EffectsSnapshotCommand < Command
      VERBS = %w[update check diff explain].freeze

      FORMATS = %w[text json].freeze
      private_constant :FORMATS

      # The verbs that read a committed record, and so accept `--baseline PATH` —
      # `--baseline <(git show origin/main:.rigor-effects.yml)` is the bot form.
      COMPARING_VERBS = %w[check diff explain].freeze
      private_constant :COMPARING_VERBS

      def initialize(argv:, verb:, out: $stdout, err: $stderr)
        super(argv: argv, out: out, err: err)
        @verb = verb
      end

      # @return [Integer] 0 fresh / written, 1 on drift under `check`, 64 on a usage error.
      def run
        options = parse_options
        return usage_error("unsupported format: #{options.fetch(:format)}") unless
          FORMATS.include?(options[:format])
        return usage_error("rigor effects #{@verb} takes no paths; it records the configured paths:") unless
          @argv.empty?

        execute(options)
      rescue OptionParser::ParseError => e
        usage_error(e.message)
      end

      private

      def execute(options)
        configuration = Configuration.load(options.fetch(:config)).with_effects_enabled
        current = build_snapshot(configuration, full: options.fetch(:full))
        return write(configuration, current) if @verb == "update"

        compare(configuration, current, options)
      end

      # ---- update -------------------------------------------------

      # Always writes — there is no generate / regenerate split, because a snapshot has no "already
      # exists" hazard: it records observations, so overwriting it is the whole point of running it.
      def write(configuration, snapshot)
        path = configuration.effects_snapshot_path
        File.write(path, snapshot.to_yaml)
        @err.puts("rigor: wrote #{path} (#{snapshot.methods.size} method(s), #{snapshot.reach.size} reach entr" \
                  "#{snapshot.reach.size == 1 ? 'y' : 'ies'})")
        # #436 — the note names what to write, not only what is missing: the same per-project preset
        # enumeration the unregistered-preset error uses, so the two can never disagree about which
        # names this project's plugin set makes available.
        if configuration.effects_snapshot_reach.empty?
          @err.puts("rigor: note — `effects.snapshot.reach:` is empty, so the snapshot records `methods:` " \
                    "only (#{Effects::EntryPoints.availability}).")
        end
        0
      end

      # ---- check / diff / explain ---------------------------------

      def compare(configuration, current, options)
        path = options.fetch(:baseline) || configuration.effects_snapshot_path
        recorded = load_recorded(path)
        return CLI::EXIT_USAGE if recorded == :error

        discharge = options.fetch(:no_tolerated) ? Effects::Discharge.none : effect_discharge(configuration)
        diff = Effects::SnapshotDiff.compare(
          recorded: recorded, current: current,
          tolerated: options.fetch(:no_tolerated) ? [] : configuration.effects_tolerated,
          gate: configuration.effects_snapshot_gate,
          strict_tolerated: options.fetch(:strict_tolerated),
          undischarged: Effects::Snapshot.undischarged_index(
            snapshot: current, table: @table, discharge: discharge
          )
        )
        return explain(diff, options) if @verb == "explain"

        EffectsDiffRenderer.new(out: @out, path: path).render(diff, format: options.fetch(:format))
        @verb == "check" && diff.drift? ? 1 : 0
      end

      def effect_discharge(configuration)
        Effects::Discharge.new(configuration.effects_tolerated)
      end

      # A missing snapshot is drift with a routed message, not an error: it is the state every project is
      # in before its first `update`, and the fix is one command away.
      def load_recorded(path)
        return nil unless File.exist?(path)

        Effects::Snapshot.load(path)
      rescue Effects::Snapshot::ParseError => e
        @err.puts("rigor: effect snapshot load failed: #{path}: #{e.message}")
        :error
      end

      # ---- explain ------------------------------------------------

      def explain(diff, options)
        rows = options.fetch(:symbol) ? rows_for_symbol(options.fetch(:symbol)) : rows_for_changes(diff)
        EffectsExplainRenderer.new(out: @out).render(rows, format: options.fetch(:format))
        0
      end

      def rows_for_symbol(symbol)
        entry = @table[symbol]
        if entry.nil?
          @err.puts("rigor: no effect unit named #{symbol}")
          return []
        end

        reach_rows(symbol, entry.proven.to_a) + method_rows(symbol, entry.direct.proven.to_a)
      end

      # Every label a change introduced, explained once: a `reach:` change gets its shortest edge path, a
      # `methods:` change gets the origin in the method's own body.
      def rows_for_changes(diff)
        diff.events.flat_map do |event|
          labels = labels_of(event)
          next [] if labels.empty?

          event.table == "reach" ? reach_rows(event.symbol, labels) : method_rows(event.symbol, labels)
        end.uniq
      end

      def labels_of(event)
        return [event.label] if event.label
        return [] unless event.category == Effects::SnapshotDiff::SYMBOL_ADDED

        entry = @table[event.symbol]
        entry ? entry.proven.to_a : []
      end

      def reach_rows(symbol, labels)
        labels.filter_map do |label|
          path = Effects::PathFinder.shortest(@table, symbol: symbol, label: label)
          next if path.nil?

          EffectsExplainRenderer::Row.new(table: "reach", symbol: symbol, label: label,
                                          path: path.to_a, origin: path.origin)
        end
      end

      def method_rows(symbol, labels)
        entry = @table[symbol]
        return [] if entry.nil?

        labels.filter_map do |label|
          origin = entry.direct.bundles.find { |_origin, set| set.include?(label) }&.first
          next if origin.nil?

          EffectsExplainRenderer::Row.new(table: "methods", symbol: symbol, label: label,
                                          path: [].freeze, origin: origin.to_s)
        end
      end

      # ---- the run ------------------------------------------------

      # Same run the report takes: collection forced on for this invocation, sequential, and going through
      # the ADR-45 whole-run result cache like `rigor check` — the diagnostics entry plus the #382 effects
      # sidecar keyed beside it, so `rigor effects check` after `rigor check` under a configured `effects:`
      # block is a warm hit plus the fixpoint.
      def build_snapshot(configuration, full:)
        runner = Analysis::Runner.new(
          configuration: configuration,
          cache_store: Cache::Store.new(root: configuration.cache_path),
          collect_stats: false,
          workers: 0
        )
        runner.run(configuration.paths)
        @table = runner.effect_table
        Effects::Snapshot.build(
          table: @table, configuration: configuration, sources: runner.effect_sources, full: full,
          registry: Effects::Registry.for_configuration(configuration,
                                                        plugin_facts: runner.effect_plugin_facts)
        )
      end

      # ---- options ------------------------------------------------

      def parse_options
        options = { config: nil, format: "text", full: false, baseline: nil, symbol: nil,
                    strict_tolerated: false, no_tolerated: false }
        OptionParser.new do |opts|
          opts.banner = "Usage: rigor effects #{@verb} [options]"
          Options.add_config(opts, options)
          add_common_options(opts, options)
          add_comparison_options(opts, options) if COMPARING_VERBS.include?(@verb)
          if @verb == "explain"
            opts.on("--symbol=KEY", "Explain this unit instead of the changed ones") do |value|
              options[:symbol] = value
            end
          end
        end.parse!(@argv)
        options
      end

      # The policy switches are accepted by every verb, `update` included, and there they are deliberately
      # inert: the record is **undischarged**, so `update --no-tolerated-effects` and `update` write
      # byte-identical files. A flag that changed the record would make the file a function of policy and
      # a policy change indistinguishable from a code change.
      def add_common_options(opts, options)
        opts.on("--format=FORMAT", "Output format: text (default) or json") { |value| options[:format] = value }
        opts.on("--full", "Record every method, including the omitted trivial and synthesised ones") do
          options[:full] = true
        end
        opts.on("--strict-tolerated", "Fail the gate on tolerated changes too (check / diff)") do
          options[:strict_tolerated] = true
        end
        opts.on("--no-tolerated-effects", "Judge as if effects.tolerated: were empty (check / diff)") do
          options[:no_tolerated] = true
        end
      end

      def add_comparison_options(opts, options)
        opts.on("--baseline=PATH", "Compare against PATH instead of effects.snapshot.path") do |value|
          options[:baseline] = value
        end
      end

      def usage_error(message)
        @err.puts(message)
        @err.puts("Usage: rigor effects #{@verb} [options]")
        CLI::EXIT_USAGE
      end
    end
  end
end
