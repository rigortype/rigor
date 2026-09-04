# frozen_string_literal: true

# Issue #674 — the per-file half of #665's fix.
#
# #665 taught the two SHARED harness entry points (`RunnerHelpers#analyze`,
# `PluginHelpers#run_plugin` / `#run_plugin_in_dir`) to raise when the `Result` carries either
# analyzer-crash diagnostic. That covers every spec routed through them and nothing else: most spec
# files build their own `Rigor::Analysis::Runner` in a local wrapper and read `.diagnostics` off the
# raw `Result`. Measured with an unconditional raise injected into `CheckRules.diagnose`, 1,177 of
# 1,925 examples across 86 such files still PASSED — an absence assertion (`not_to include(...)`,
# `be_empty`, `all(eq(...))`) holds trivially on the single-diagnostic list a crashed rule leaves
# behind, so those examples were not testing their claim at all.
#
# Rerouting every local wrapper through `RunnerHelpers#analyze` was not an option: the wrappers
# differ in the things `analyze` fixes (cache store, `paths:`, plugin requirer, chdir root), so a
# reroute would change WHAT each spec exercises. These two helpers change only WHETHER a crash can
# hide the answer — they run the same call the wrapper already ran and pass the `Result` through
# {InternalAnalyzerErrorGuard.check!} before the spec sees it.
#
# Use them at the construction site:
#
#     guarded_run(Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil))
#     guarded_run(described_class.new(configuration: configuration), %w[app.rb])
#     guarded_run_source(Rigor::Analysis::Runner.new(configuration: config), source: src, path: "mem.rb")
#
# `spec/docs/spec_analyzer_guard_spec.rb` is the regrowth gate: it rejects a NEW `…Runner.new(…).run`
# whose result is not guarded, so the population this module drains cannot rebuild itself.
#
# Issue #683 — `IncrementalSession` is a THIRD analyzer entry point (`Runner` and `WorkerSession` are
# the other two), reached via `#baseline` / `#recheck` / `#run_incremental` / `#run_buffer_recheck`,
# each with its own return shape. Measured with the same unconditional `CheckRules.diagnose` raise,
# 14 of 60 `incremental_session_spec.rb` examples still passed, and every one sampled turned out to be
# a coincidence rather than an absence check: a crashed rule makes `Runner#analyze_file_body` rescue
# into one deterministic `"internal analyzer error"` diagnostic per file, so a `--verify-incremental`
# style oracle comparison (`recheck.diagnostics == full_run(dir)`) gets the SAME synthetic diagnostic
# on both sides and reports equal. `guarded_baseline` / `guarded_recheck` / `guarded_run_incremental` /
# `guarded_run_buffer_recheck` close that the same way the two helpers above do: at the call site,
# before the spec's own comparison runs.
module GuardedAnalysis
  # @param runner [Rigor::Analysis::Runner]
  # @param paths [Array<String>, nil] forwarded to `Runner#run` when given; omitted (so the
  #   configuration's own `paths` apply) when nil, which is the dominant call shape.
  # @param allow_plugin_crash [Boolean] see {InternalAnalyzerErrorGuard.check!} — only for the examples
  #   that deliberately crash a plugin to assert the runner's isolation envelope.
  # @return [Rigor::Analysis::Result]
  # @raise [InternalAnalyzerErrorGuard::AnalyzerCrashed]
  def guarded_run(runner, paths = nil, allow_plugin_crash: false)
    result = paths.nil? ? runner.run : runner.run(paths)
    InternalAnalyzerErrorGuard.check!(
      result, context: guarded_analysis_context("guarded_run"), allow_plugin_crash: allow_plugin_crash
    )
  end

  # @return [Rigor::Analysis::Result]
  # @raise [InternalAnalyzerErrorGuard::AnalyzerCrashed]
  def guarded_run_source(runner, source:, path: "(source).rb")
    result = runner.run_source(source: source, path: path)
    InternalAnalyzerErrorGuard.check!(result, context: guarded_analysis_context("guarded_run_source"))
  end

  # `WorkerSession#analyze(path)` — the per-file entry the pool workers drive, which returns
  # `Array<Diagnostic>` rather than a `Result`, so it needs the Array-shaped guard.
  #
  # @param session [Rigor::Analysis::WorkerSession]
  # @return [Array<Rigor::Analysis::Diagnostic>]
  # @raise [InternalAnalyzerErrorGuard::AnalyzerCrashed]
  def guarded_session_analyze(session, path, allow_plugin_crash: false)
    InternalAnalyzerErrorGuard.check_diagnostics!(
      session.analyze(path),
      context: guarded_analysis_context("guarded_session_analyze"), allow_plugin_crash: allow_plugin_crash
    )
  end

  # Issue #683 — `IncrementalSession` is a third analyzer entry point, alongside `Runner` and
  # `WorkerSession`. `#baseline` returns `Array<Diagnostic>` directly (mirrors `WorkerSession#analyze`,
  # hence the Array-shaped guard).
  #
  # @param session [Rigor::Analysis::IncrementalSession]
  # @return [Array<Rigor::Analysis::Diagnostic>]
  # @raise [InternalAnalyzerErrorGuard::AnalyzerCrashed]
  def guarded_baseline(session)
    InternalAnalyzerErrorGuard.check_diagnostics!(
      session.baseline, context: guarded_analysis_context("guarded_baseline")
    )
  end

  # `IncrementalSession#recheck` returns a `Recheck` (`Data.define(:diagnostics, :changed, :added,
  # :removed, :affected, :reused)`), not a bare Array, so the guard checks its `#diagnostics` field and
  # hands back the whole struct — every call site reads `changed` / `affected` / `reused` off it too.
  #
  # @param session [Rigor::Analysis::IncrementalSession]
  # @return [Rigor::Analysis::IncrementalSession::Recheck]
  # @raise [InternalAnalyzerErrorGuard::AnalyzerCrashed]
  def guarded_recheck(session)
    result = session.recheck
    InternalAnalyzerErrorGuard.check_diagnostics!(
      result.diagnostics, context: guarded_analysis_context("guarded_recheck")
    )
    result
  end

  # `IncrementalSession#reanalyze_subset` — the verification engine (`--verify-incremental`). Returns
  # `Array<Diagnostic>` directly (the merged diagnostics), so the guard checks the returned array.
  #
  # @param session [Rigor::Analysis::IncrementalSession]
  # @param subset [Enumerable<String>]
  # @return [Array<Rigor::Analysis::Diagnostic>]
  # @raise [InternalAnalyzerErrorGuard::AnalyzerCrashed]
  def guarded_reanalyze_subset(session, subset)
    InternalAnalyzerErrorGuard.check_diagnostics!(
      session.reanalyze_subset(subset), context: guarded_analysis_context("guarded_reanalyze_subset")
    )
  end

  # `IncrementalSession#run_incremental` — the `--incremental` CLI engine — returns `[diagnostics,
  # warm]`. Guards the diagnostics half and hands back the same tuple.
  #
  # @param session [Rigor::Analysis::IncrementalSession]
  # @return [Array(Array<Rigor::Analysis::Diagnostic>, Boolean)]
  # @raise [InternalAnalyzerErrorGuard::AnalyzerCrashed]
  def guarded_run_incremental(session, snapshot:, fingerprint:, persist: true)
    diagnostics, warm = session.run_incremental(snapshot: snapshot, fingerprint: fingerprint, persist: persist)
    InternalAnalyzerErrorGuard.check_diagnostics!(
      diagnostics, context: guarded_analysis_context("guarded_run_incremental")
    )
    [diagnostics, warm]
  end

  # `IncrementalSession#run_buffer_recheck` — editor-mode option B (#146). Returns nil when the
  # snapshot could not be reused, a legitimate decline (nothing ran) rather than a crash, so the guard
  # applies only to a non-nil `Recheck`.
  #
  # @param session [Rigor::Analysis::IncrementalSession]
  # @return [Rigor::Analysis::IncrementalSession::Recheck, nil]
  # @raise [InternalAnalyzerErrorGuard::AnalyzerCrashed]
  def guarded_run_buffer_recheck(session, snapshot:, fingerprint:)
    result = session.run_buffer_recheck(snapshot: snapshot, fingerprint: fingerprint)
    return result if result.nil?

    InternalAnalyzerErrorGuard.check_diagnostics!(
      result.diagnostics, context: guarded_analysis_context("guarded_run_buffer_recheck")
    )
    result
  end

  private

  # Names the example that hid the crash, not just the helper: the whole point of the guard is to
  # point at the spec whose assertion was vacuous, and a bare helper name does not do that.
  def guarded_analysis_context(helper)
    location = RSpec.current_example&.location
    location ? "#{helper} (#{location})" : helper
  end
end

RSpec.configure { |config| config.include GuardedAnalysis }
