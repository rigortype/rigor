# frozen_string_literal: true

module Rigor
  class CLI
    # The one place a CLI command turns a loaded {Configuration} into an {Analysis::Result}.
    #
    # {CheckRunnerFactory} builds the runner; this module owns the *invocation* wrapped around it — resolving the
    # analysed paths, running, and handing back both the runner (`rigor check`'s reporting tail still needs its cache
    # store and stats) and the raw result. It exists so a non-`check` command — `rigor doctor`, `rigor skill describe
    # --deep` — reaches a check result through the same code path `rigor check` walks, instead of re-deriving the
    # plumbing (issue #148; ADR-73 § "Field-trial follow-ups" names the shared helper as the prerequisite).
    #
    # Nothing here is required at load time: {CheckRunnerFactory} pulls the inference engine, so both entry points
    # require it lazily. A command that merely *mentions* this module therefore stays engine-free until it actually
    # runs an analysis — the property ADR-87 WD4 protects for `rigor check`'s cache-hit fast path, and the property
    # that keeps an un-flagged `rigor skill describe` from loading the engine at all.
    module CheckInvocation
      # A completed analysis. `runner` is exposed because `rigor check`'s tail reads its `cache_store` (eviction,
      # `--cache-stats`) and feeds it to `--coverage`; `result` is the raw, pre-baseline-filter {Analysis::Result}.
      Invocation = Data.define(:runner, :result)

      # The outcome of {.attempt} — the best-effort variant. Exactly one of the two is non-nil, so a caller can never
      # read "the check could not run" as "the check ran clean": `result` is nil precisely when `error` is set.
      Outcome = Data.define(:result, :error) do
        # @rbs return: bool -- True when an analysis actually completed.
        def ran?
          !result.nil?
        end
      end

      # Options for a caller that wants a check *result* rather than a check *run*: no cache writes, no explain
      # traces, sequential. `stats: true` because the RBS-environment signal (`stats.rbs_classes_total`) lives there.
      # This is `rigor doctor`'s preset — a diagnostic command that must not churn the project's cache.
      READ_ONLY_OPTIONS = { no_cache: true, explain: false, stats: true, workers: 0 }.freeze

      # Options for an opt-in deep probe (`rigor skill describe --deep`). Unlike {READ_ONLY_OPTIONS} this uses the
      # configured cache and worker count, i.e. it behaves exactly like `rigor check` — fast on a warm cache, and it
      # WRITES `.rigor/cache`. That side effect is the whole reason the flag is opt-in.
      DEEP_OPTIONS = { no_cache: false, explain: false, stats: true, workers: nil }.freeze

      module_function

      # Runs the analysis the way `rigor check` does and returns the runner + its raw result.
      #
      # @rbs options: Hash[untyped, untyped] --
      #   At least `:no_cache`, `:explain`, `:stats`, `:workers` (see {CheckRunnerFactory.build}).
      # @rbs paths: Array[String]? -- Analysed paths; nil falls back to the configuration's `paths:`.
      # @rbs cache_root: String? -- Nil falls back to the configuration's cache path.
      def run(configuration:, options:, paths: nil, buffer: nil, cache_root: nil)
        require_relative "check_runner_factory"
        runner = CheckRunnerFactory.build(
          configuration: configuration,
          options: options,
          buffer: buffer,
          cache_root: cache_root || configuration.cache_path
        )
        Invocation.new(runner: runner, result: runner.run(paths || configuration.paths))
      end

      # Best-effort variant for a *routing* caller: one that wants to sharpen a recommendation with check evidence and
      # has a perfectly good answer when there is none. Loads the configuration itself and converts every way the run
      # can fail outright — an unreadable / invalid config, an unloadable plugin, an engine error — into an {Outcome}
      # carrying a short human-readable `error`. It never raises and never fabricates a clean result.
      #
      # Deliberately broad: the caller's contract is "degrade to the presence-only answer, whatever went wrong". A
      # routing hint is outside the false-positive envelope, but a crash in it is not — `describe` must stay a command
      # an agent can run freely.
      #
      # @rbs config_path: String? -- Path to the config file; nil uses {Configuration.discover}.
      # @rbs options: Hash[untyped, untyped] -- Runner options (defaults to {DEEP_OPTIONS}).
      def attempt(config_path: nil, options: DEEP_OPTIONS, paths: nil)
        require_relative "../configuration"
        configuration = Configuration.load(config_path)
        Outcome.new(result: run(configuration: configuration, options: options, paths: paths).result, error: nil)
      rescue StandardError, LoadError => e
        Outcome.new(result: nil, error: "#{e.class}: #{e.message.to_s.lines.first.to_s.strip}")
      end
    end
  end
end
