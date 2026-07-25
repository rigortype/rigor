# frozen_string_literal: true

require_relative "check_invocation"

module Rigor
  class CLI
    # `rigor skill describe --deep` — the one part of `describe` that runs an analysis (issue #148; ADR-73
    # § "Field-trial follow-ups", the "headline check-awareness" open decision, shape (b)).
    #
    # **The boundary is this file.** ADR-73 WD2 makes `describe` presence-only and side-effect-free, and that
    # guardrail binds the *un-flagged* command exactly as before: {SkillDescribe} requires this file only when
    # `--deep` was passed, so a default `rigor skill describe` never loads the inference engine, never opens a
    # project source file, and writes nothing. `--deep` is the opt-in that trades that purity away: it runs a real
    # `rigor check` over the configured paths using the configured cache and worker count, so it is as slow as
    # `rigor check` on a cold cache and it WRITES `.rigor/cache` just like `rigor check` does.
    #
    # The routing vocabulary is deliberately the one `describe`'s "For the agent" section already teaches (errors →
    # `rigor-baseline-reduce`, a proven monkey-patch cluster → `rigor-monkeypatch-resolve`, an empty RBS environment
    # or a `configuration-error` → `rigor-doctor`). `--deep` makes the headline compute the call the agent would
    # otherwise make from the same evidence; it does not introduce a second taxonomy.
    class SkillDeepProbe
      # Diagnostics the engine emits when the *setup* is broken rather than the code — the `rigor-doctor` signal.
      CONFIGURATION_ERROR_RULE = "configuration-error"

      # The share of a run's errors that must be proven monkey-patches before the headline routes to
      # `rigor-monkeypatch-resolve` rather than `rigor-baseline-reduce`. The agent-prompt vocabulary this reuses says
      # "a monkey-patch *cluster*", and a cluster is what makes the workflow the right one: `pre_eval:` clears those
      # sites wholesale, so it is the shortest path only when clearing them materially changes the count. One proven
      # site beside four hundred unrelated errors is a true finding pointing at the wrong workflow — the report says
      # so in the reason line either way, so nothing is lost by leaving the headline on the bigger problem.
      MONKEY_PATCH_CLUSTER_SHARE = Rational(1, 3)

      # What the deep check concluded.
      #
      # - `status` — `:skipped` (no config to check), `:error` (the check could not run), `:analyzed` (it ran).
      # - `detail` — the human line printed under "## Deep check"; on `:error` it says so outright, because a check
      #   that could not run is NOT a clean check and the report must never let it read as one.
      # - `route` / `reason` — the headline override, or nil to leave the presence-only recommendation standing.
      Report = Data.define(:status, :detail, :route, :reason) do
        # @return [Boolean] true when the check did not complete — the caller must then say so rather than let the
        #   fallback recommendation read as an all-clear.
        def failed?
          status == :error
        end
      end

      # @param config [String, nil] the config filename the presence probe found, relative to `root`.
      # @param root [String] project root (the analysis itself resolves paths against the process cwd, as
      #   `rigor check` does).
      def initialize(config:, root: Dir.pwd)
        @config = config
        @root = root
      end

      # @return [Report] never raises — every failure degrades to a `:error`/`:skipped` report whose `route` is nil,
      #   leaving the presence-only headline in charge.
      def run
        if @config.nil?
          return Report.new(
            status: :skipped, route: nil, reason: nil,
            detail: "skipped — this project has no Rigor configuration, so there is nothing to check yet."
          )
        end

        outcome = CheckInvocation.attempt(config_path: File.join(@root, @config))
        return failed(outcome.error) unless outcome.ran?

        classify(outcome.result)
      end

      private

      # A check that could not run at all. Reported as a failure, not as a clean result, and with the raw error text
      # so the user can act on it — the un-run check is itself a finding, but not one precise enough to route on.
      def failed(error)
        Report.new(
          status: :error, route: nil, reason: nil,
          detail: "the check could NOT run: #{error}. This is not a clean result — the recommendation below " \
                  "falls back to the presence-only probe. Run `rigor check` (or `rigor doctor`) to see what failed."
        )
      end

      def classify(result)
        sites = monkey_patch_diagnostics(result)
        if broken_environment?(result)
          doctor_report(result)
        elsif monkey_patch_cluster?(result, sites)
          monkeypatch_report(result, sites)
        elsif result.error_count.positive?
          baseline_report(result, sites)
        else
          Report.new(
            status: :analyzed, route: nil, reason: nil,
            detail: "the check ran clean — 0 error diagnostics. The recommendation below is the presence-only one."
          )
        end
      end

      # The `rigor-doctor` signal, read exactly as `rigor doctor` itself reads it: an RBS environment that built to
      # zero classes (analysis is hollow, so every other count is meaningless), or a `configuration-error` the run
      # already emitted. Checked first — with a broken setup the remaining diagnostics are not evidence of anything.
      def broken_environment?(result)
        result.stats&.rbs_classes_total&.zero? ||
          result.diagnostics.any? { |diagnostic| diagnostic.rule == CONFIGURATION_ERROR_RULE }
      end

      # ADR-17 / the `project-monkey-patch-known` triage recogniser: `call.undefined-method` sets
      # `project_definition_site` when the project itself defines the called method on the receiver class somewhere
      # in the analysed file set. That is engine-proven evidence, not a spread heuristic, which is why it routes with
      # no count threshold — and why the *unproven* shapes (a bare `call.unresolved-toplevel` count, "framework calls
      # typing as Dynamic") are deliberately not routed on here. Guessing a workflow from a weak signal is worse than
      # leaving the generic recommendation standing.
      def monkey_patch_diagnostics(result)
        result.diagnostics.select(&:project_definition_site)
      end

      # Whether the proven sites dominate the run enough for `pre_eval:` to be the shortest path. Any proven site is
      # real evidence — `project_definition_site` is engine-proven, not a spread heuristic — but evidence of a *site*
      # is not evidence that clearing it is the next thing to do. Below the share, `baseline_report` still names the
      # sites, so the finding survives even when the headline does not follow it.
      def monkey_patch_cluster?(result, sites)
        return false if sites.empty?
        return true unless result.error_count.positive?

        Rational(sites.size, result.error_count) >= MONKEY_PATCH_CLUSTER_SHARE
      end

      def doctor_report(result)
        classes = result.stats&.rbs_classes_total
        cause = if classes&.zero?
                  "the RBS environment built to 0 classes"
                else
                  "the run emitted a `#{CONFIGURATION_ERROR_RULE}` diagnostic"
                end
        Report.new(
          status: :analyzed, route: "rigor-doctor",
          reason: "a `--deep` check found a broken setup (#{cause}) — the analysis is hollow until that is fixed, " \
                  "so no other finding is trustworthy yet.",
          detail: "the check found a broken setup — #{cause}."
        )
      end

      def monkeypatch_report(result, sites)
        files = sites.filter_map { |d| d.project_definition_site&.sub(/:\d+\z/, "") }.uniq.sort
        Report.new(
          status: :analyzed, route: "rigor-monkeypatch-resolve",
          reason: "a `--deep` check found #{sites.size} call site(s) that resolve to the project's own definitions " \
                  "in #{files.first(3).join(', ')} — reopened classes Rigor does not apply cross-file. Listing " \
                  "them in `pre_eval:` clears them wholesale.",
          detail: "the check reported #{result.error_count} error diagnostic(s), #{sites.size} of them proven " \
                  "project monkey-patches (#{files.size} file(s))."
        )
      end

      def baseline_report(result, sites = [])
        aside = if sites.empty?
                  ""
                else
                  " #{sites.size} of them are proven project monkey-patches — too small a share to make `pre_eval:` " \
                    "the shortest path, but `rigor-monkeypatch-resolve` clears them if you want them gone first."
                end
        Report.new(
          status: :analyzed, route: "rigor-baseline-reduce",
          reason: "a `--deep` check reported #{result.error_count} error diagnostic(s) — work them down (or record " \
                  "them in a baseline) before adding more surface.#{aside}",
          detail: "the check reported #{result.error_count} error diagnostic(s), " \
                  "#{sites.empty? ? 'none' : sites.size} of them proven project monkey-patches."
        )
      end
    end
  end
end
