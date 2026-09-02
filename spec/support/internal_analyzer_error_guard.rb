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
module InternalAnalyzerErrorGuard
  # A named class rather than a bare RuntimeError so a caller-side `rescue StandardError` — or a future
  # `expect { ... }.to raise_error(RuntimeError)` written for an unrelated reason — cannot accidentally
  # swallow, or count as a pass, a fire this guard did not intend it to catch.
  class AnalyzerCrashed < StandardError; end

  CHECK_RULE_CRASH_MESSAGE_PREFIX = "internal analyzer error"
  PLUGIN_CRASH_RULE = "runtime-error"
  PLUGIN_CRASH_SOURCE_FAMILY = :plugin_loader

  # @param result [Rigor::Analysis::Result]
  # @param context [String] the calling helper's name, prefixed onto the raised message so a failure points
  #   straight at which harness entry point saw the crash.
  # @return [Rigor::Analysis::Result] `result`, unchanged, when no diagnostic matches {.crash?}.
  # @raise [AnalyzerCrashed]
  def self.check!(result, context:)
    culprit = result.diagnostics.find { |d| crash?(d) }
    return result if culprit.nil?

    raise AnalyzerCrashed,
          "#{context}: the analyzer crashed instead of producing real diagnostics " \
          "(#{culprit.path}:#{culprit.line}: #{culprit.message}) — a check rule or plugin raised; " \
          "this is a real bug, not a spec-harness issue. See issue #665."
  end

  # True for either of the two rescue-produced diagnostics documented above. Deliberately keyed on the
  # structured `(severity, source_family, rule)` triple for the plugin-crash case rather than on the bare
  # rule name `"runtime-error"` or `"load-error"` alone — a plugin is free to define its own rule under its
  # OWN `source_family: "plugin.<id>"` (several guarded specs assert a plugin-authored `"load-error"`
  # legitimately), and only the `:plugin_loader` family paired with `"runtime-error"` is this rescue's own.
  def self.crash?(diagnostic)
    return true if diagnostic.message.start_with?(CHECK_RULE_CRASH_MESSAGE_PREFIX)

    diagnostic.severity == :error &&
      diagnostic.source_family == PLUGIN_CRASH_SOURCE_FAMILY &&
      diagnostic.rule == PLUGIN_CRASH_RULE
  end
end
