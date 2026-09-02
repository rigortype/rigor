# frozen_string_literal: true

# Issue #665 — `Runner#analyze_file_body` / `WorkerSession#analyze_body` rescue `StandardError` around a
# file's analysis and fold whatever a check rule or plugin raised into ONE diagnostic for that file:
# `"internal analyzer error: <class>: <msg>"`, `rule: nil`, discarding every diagnostic that file would
# otherwise have produced. In the CLI that is loud and correct — `Result#success?` goes false, so `rigor
# check` exits 1 and CI goes red.
#
# In the spec harness it is silent. `rules(result)` maps `qualified_rule`, which is nil for an internal
# analyzer error, so `expect(rules(result)).not_to include("some.rule")` holds; `expect(dumps(result)).to
# all(eq(...))` passes vacuously on the empty list the crash leaves behind. A rule that raises instead of
# firing reads, to the harness, as a rule that correctly declined to fire.
#
# No spec in this suite should legitimately produce this diagnostic, so every helper that returns a
# `Rigor::Analysis::Result` — `RunnerHelpers#analyze` and `PluginHelpers#run_plugin` / `#run_plugin_in_dir`
# — calls {.check!} before handing the result back. That converts "the rule silently didn't run" into a
# loud failure at the exact spec that hid it, instead of an absence assertion passing for the wrong reason.
module InternalAnalyzerErrorGuard
  MESSAGE_PREFIX = "internal analyzer error"

  # @param result [Rigor::Analysis::Result]
  # @param context [String] the calling helper's name, prefixed onto the raised message so a failure points
  #   straight at which harness entry point saw the crash.
  # @return [Rigor::Analysis::Result] `result`, unchanged, when no diagnostic carries the crash prefix.
  def self.check!(result, context:)
    culprit = result.diagnostics.find { |d| d.message.start_with?(MESSAGE_PREFIX) }
    return result if culprit.nil?

    raise "#{context}: the analyzer crashed instead of producing real diagnostics " \
          "(#{culprit.path}:#{culprit.line}: #{culprit.message}) — a check rule or plugin raised; " \
          "this is a real bug, not a spec-harness issue. See issue #665."
  end
end
