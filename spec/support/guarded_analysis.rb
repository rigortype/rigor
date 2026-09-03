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

  private

  # Names the example that hid the crash, not just the helper: the whole point of the guard is to
  # point at the spec whose assertion was vacuous, and a bare helper name does not do that.
  def guarded_analysis_context(helper)
    location = RSpec.current_example&.location
    location ? "#{helper} (#{location})" : helper
  end
end

RSpec.configure { |config| config.include GuardedAnalysis }
