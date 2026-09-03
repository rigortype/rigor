# frozen_string_literal: true

# Issue #665 — the analyzer swallows two DIFFERENT classes of crash into a diagnostic instead of letting the
# exception propagate, and the spec harness must not let either one masquerade as "the rule declined to
# fire":
#
# 1. A CHECK RULE (or a plugin's own node-rule contribution) raising inside `CheckRules.diagnose` is caught
#    by `Runner#analyze_file_body`'s `rescue StandardError` (`lib/rigor/analysis/runner.rb:1736-1746`) or
#    `WorkerSession#analyze_body`'s twin (`lib/rigor/analysis/worker_session.rb:229-231`), and folds into
#    ONE diagnostic for the whole file: `"internal analyzer error: <class>: <msg>"`, `rule: nil`.
# 2. A PLUGIN raising from `#diagnostics_for_file` or `#prepare` is caught separately —
#    `Runner#collect_plugin_diagnostics` (`runner.rb` ~L1447-1481) and
#    `Runner::ProjectPrePasses#invoke_plugin_prepare` (`runner/project_pre_passes.rb` ~L307-326) — into a
#    diagnostic with `rule: "runtime-error"`, `source_family: :plugin_loader`, `severity: :error`. Its
#    message never starts with "internal analyzer error", so a prefix-only guard misses it entirely; worse,
#    `PluginHelpers#plugin_diagnostics` filters on `source_family == "plugin.<id>"`, a String, which never
#    equals the Symbol `:plugin_loader` — so `expect(plugin_diagnostics(result)).to be_empty` passes on a
#    crashed plugin exactly the way an absence assertion on `rules(result)` passes on a crashed check rule.
#
# In the CLI both are loud and correct — `Result#success?` goes false, so `rigor check` exits 1 and CI goes
# red. In the spec harness both are silent: `rules(result)` maps `qualified_rule`, which is nil for case 1,
# so `expect(rules(result)).not_to include("some.rule")` holds; `expect(dumps(result)).to all(eq(...))`
# passes vacuously on the empty list either crash leaves behind; and case 2 additionally slips past
# `plugin_diagnostics`'s family filter even when a spec asserts on it directly.
#
# No spec in this suite should legitimately produce either diagnostic (the load-error family a plugin
# genuinely CAN fire in a guarded spec, `source_family: "plugin.<id>", rule: "load-error"`, is a plugin's
# own diagnostic, not this rescue's — {.crash?} never matches on bare rule names, only on this exact
# `(severity, source_family, rule)` triple, so it cannot collide). So every helper that returns a
# `Rigor::Analysis::Result` — `RunnerHelpers#analyze` and `PluginHelpers#run_plugin` / `#run_plugin_in_dir`
# — calls {.check!} before handing the result back, converting "the rule (or plugin) silently didn't run"
# into a loud failure at the exact spec that hid it. `spec/integration/internal_analyzer_error_guard_spec.rb`
# pins that the guard actually fires through these two real rescue sites (not just against a hand-built
# diagnostic), so a future rewording of either message can't silently disarm it.
#
# Issue #696 — what a crash diagnostic LOOKS like is no longer this file's own knowledge. Both shapes are
# defined once in {Rigor::Analysis::CrashSignature} and reached here through it, because two consumers inside
# `lib/` need the same answer ({Rigor::Analysis::Result#crashed?} and the ADR-69 kill oracles, issue #686) and
# a third independent string match on a diagnostic message is a disarming waiting to happen — a reworded
# message would silently un-arm whichever copies were not updated, and nothing would go red. What stays local
# to this file is the spec-harness POLICY: the `allow_plugin_crash:` escape hatch, and a message that names
# the example which hid the crash.
require "rigor/analysis/crash_signature"

module InternalAnalyzerErrorGuard
  # A named class rather than a bare RuntimeError so a caller-side `rescue StandardError` — or a future
  # `expect { ... }.to raise_error(RuntimeError)` written for an unrelated reason — cannot accidentally
  # swallow, or count as a pass, a fire this guard did not intend it to catch.
  class AnalyzerCrashed < StandardError; end

  # @param result [Rigor::Analysis::Result]
  # @param context [String] the calling helper's name, prefixed onto the raised message so a failure points
  #   straight at which harness entry point saw the crash.
  # @param allow_plugin_crash [Boolean] for the handful of examples whose SUBJECT is the runner's own
  #   plugin-isolation envelope (`runner_spec.rb`'s "isolates plugin exceptions …" / "isolates a #prepare
  #   raise …"): there the `:plugin_loader` / `"runtime-error"` diagnostic is what the example asserts on, so
  #   raising on it would make the behaviour untestable. The CHECK-RULE half stays armed regardless — a rule
  #   crashing in one of those runs would still hide the answer, and no spec has a reason to want that.
  # @return [Rigor::Analysis::Result] `result`, unchanged, when no diagnostic matches {.crash?}.
  # @raise [AnalyzerCrashed]
  def self.check!(result, context:, allow_plugin_crash: false)
    check_diagnostics!(result.diagnostics, context: context, allow_plugin_crash: allow_plugin_crash)
    result
  end

  # The bare-Array twin of {.check!}, for the per-file surface that returns diagnostics rather than a
  # `Result`: `WorkerSession#analyze(path)` is the public entry the fork/Ractor workers call, and it hands
  # back `Array<Diagnostic>`. Without this there is no seam for it at all, which is how
  # `worker_session_spec`'s Runner-vs-session equivalence examples stayed vacuous under #674 — a crashed
  # rule makes BOTH sides one identical diagnostic, so `eq` holds (issue #674 review).
  #
  # @param diagnostics [Array<Rigor::Analysis::Diagnostic>]
  # @return [Array<Rigor::Analysis::Diagnostic>] `diagnostics`, unchanged, when none matches {.crash?}.
  # @raise [AnalyzerCrashed]
  def self.check_diagnostics!(diagnostics, context:, allow_plugin_crash: false)
    culprit = diagnostics.find { |d| crash?(d, allow_plugin_crash: allow_plugin_crash) }
    return diagnostics if culprit.nil?

    raise AnalyzerCrashed,
          "#{context}: the analyzer crashed instead of producing real diagnostics " \
          "(#{culprit.path}:#{culprit.line}: #{culprit.message}) — a check rule or plugin raised; " \
          "this is a real bug, not a spec-harness issue. See issue #665."
  end

  # True for either of the two rescue-produced diagnostics documented above. The SHAPES live in
  # {Rigor::Analysis::CrashSignature} (issue #696) — including why the plugin case is keyed on the
  # structured `(severity, source_family, rule)` triple rather than on the bare rule name. What this method
  # adds is the harness policy: `allow_plugin_crash:` drops the plugin half for the handful of examples
  # whose subject IS the isolation envelope, and the check-rule half stays armed regardless.
  #
  # `CrashSignature` also classifies a third shape, `:rbs_build` (`rbs.coverage.definition-build-failed` /
  # `rbs.coverage.environment-build-failed`, issue #696). It is deliberately NOT armed here: the analysis
  # ran to completion in that case, `spec/integration/environment_build_failed_spec.rb` produces one on
  # purpose, and how many other fixtures collide with Rigor's bundled RBS has not been measured. Arming it
  # is its own change, with that measurement in front of it.
  def self.crash?(diagnostic, allow_plugin_crash: false)
    reason = Rigor::Analysis::CrashSignature.reason(diagnostic)
    return false if reason == :plugin && allow_plugin_crash

    Rigor::Analysis::CrashSignature::ANALYZER_FAILED_REASONS.include?(reason)
  end
end
