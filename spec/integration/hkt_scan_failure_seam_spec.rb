# frozen_string_literal: true

# Issue #784 — the design's own proof, through a REAL `Runner`. `Environment#hkt_registry` is a shared,
# memoised build first demanded from inside a file's analysis (the dispatcher's Singleton-receiver HKT
# builtin tier, `MethodDispatcher#try_hkt_builtin_return`); before the seam in `Environment#hkt_registry`
# a raise there landed in every file's `analyze_body` rescue and the run came back as N identical
# `internal analyzer error` rows with nothing saying the analyzer never ran (issue #776). The seam rescues
# at `Environment#hkt_registry`, records the failure, and degrades to the pre-scan registry so analysis
# proceeds; this file pins that the run-level `rbs.coverage.hkt-scan-failed` row is what a caller sees
# instead — never a per-file crash row.
#
# `InternalAnalyzerErrorGuard` (armed by `RunnerHelpers#analyze` on every call) never trips on a `:rbs_build`
# row — it is the ONE shape the guard deliberately leaves unarmed (the analysis ran to completion over a
# degraded universe; see `spec/support/internal_analyzer_error_guard.rb`). So the absence of `AnalyzerCrashed`
# below is not merely "the guard didn't fire" — it is the guard PROVING this row is `:rbs_build`, not
# `:check_rule`, using the exact same classification `Result#crashed?` and the ADR-69 kill oracles read.
require "spec_helper"

RSpec.describe "HKT scan-failure seam (issue #784)" do
  include RunnerHelpers

  before do
    allow(Rigor::Inference::HktRegistry).to receive(:scan_rbs_loader).and_raise(NameError, "simulated scan bug")
  end

  # `JSON.parse` is a Singleton-receiver call the dispatcher's ADR-20 slice 3 tier consults
  # (`Builtins::HktBuiltins::METHOD_RETURN_OVERRIDES`), and consulting it is what demands
  # `environment.hkt_registry` at all — an ordinary receiverless call (`1.to_s`, a local `def`, …) never
  # reaches that tier, so the scan is never demanded and this spec would be vacuous against one.
  # A real finding rides alongside, so the spec can tell "the seam surfaced one row" apart from "every
  # other diagnostic vanished" — the #776 shape this exists to rule out.
  let(:source) { "JSON.parse(\"{}\")\n\"x\".lenght\n" }

  it "does not raise AnalyzerCrashed — the row is :rbs_build, not :check_rule" do
    expect { analyze(source) }.not_to raise_error
  end

  it "surfaces exactly one rbs.coverage.hkt-scan-failed :error row, keeps the file's real diagnostics, " \
     "and emits no internal-analyzer-error row" do
    result = analyze(source)

    expect(Rigor::Inference::HktRegistry).to have_received(:scan_rbs_loader).at_least(:once)

    matching = result.diagnostics.select { |d| d.rule == "rbs.coverage.hkt-scan-failed" }
    expect(matching.size).to eq(1)
    expect(matching.first.severity).to eq(:error)
    expect(matching.first.message).to include("NameError", "simulated scan bug")

    expect(result.diagnostics.map(&:rule)).to include("call.undefined-method")

    expect(result.diagnostics.map(&:message))
      .to satisfy("no diagnostic starting with the check-rule prefix") do |messages|
        messages.none? { |m| m.start_with?("internal analyzer error") }
      end
  end

  # Suppressible only the way its `rbs.coverage.*` siblings are (diagnostic-policy.md): a severity override
  # — exact id or the `rbs` family — removes it; `disable:` does not, because the row is not a check rule.
  # `cache_store: nil` throughout: the shared ADR-45 run cache could serve one example's diagnostics to
  # another whose config + source collide on the key, and an absence assertion would then pass vacuously.
  describe "suppressibility" do
    it "is removed by an exact severity_overrides: off" do
      result = analyze(source, cache_store: nil,
                               config: { "severity_overrides" => { "rbs.coverage.hkt-scan-failed" => "off" } })
      expect(result.diagnostics.map(&:rule)).not_to include("rbs.coverage.hkt-scan-failed")
      expect(result.diagnostics.map(&:rule)).to include("call.undefined-method") # the run still ran
    end

    it "is removed by the rbs family severity_overrides: off" do
      result = analyze(source, cache_store: nil, config: { "severity_overrides" => { "rbs" => "off" } })
      expect(result.diagnostics.map(&:rule)).not_to include("rbs.coverage.hkt-scan-failed")
      expect(result.diagnostics.map(&:rule)).to include("call.undefined-method")
    end

    it "is NOT removed by disable:" do
      result = analyze(source, cache_store: nil, config: { "disable" => ["rbs.coverage.hkt-scan-failed"] })
      rows = result.diagnostics.select { |d| d.rule == "rbs.coverage.hkt-scan-failed" }
      expect(rows.size).to eq(1)
      expect(rows.first.severity).to eq(:error)
    end
  end

  # Issue #791 — the OTHER build behind `Environment#hkt_registry`. The plugin-overlay merge sat one line
  # ABOVE the #784 rescue, so a raise from a plugin's manifest escaped the getter; post-#788 that is not a
  # per-file crash storm but an uncaught abort, because the holder memoises only on success and the
  # run-owned demands (`PoolCoordinator#hkt_scan_outcome` after the file loop, `WorkerSession#drain_reporters`)
  # have no rescue above them. Nothing in today's tree can trigger it — `Manifest` validates registrations at
  # construction and the loader demands `manifest` at load — so the raise is staged here.
  describe "the plugin-overlay stage (issue #791)" do
    # The registry a run holds is FROZEN, so no partial double can reach it; a real `Plugin::Registry`
    # subclass carries the raise on the class instead. Injected through `Environment.for_project`, which is
    # every environment-building site the run has — the sequential resolve and each pool worker alike. The
    # message is the shape `Plugin::Registry#hkt_overlay_registry`'s per-plugin rescue produces (pinned in
    # `spec/rigor/plugin/registry_spec.rb`), so the row's text here is the text a real plugin defect gets.
    let(:raising_plugin_registry) do
      Class.new(Rigor::Plugin::Registry) do
        def hkt_overlay_registry
          raise ArgumentError,
                'plugin "hktboom" raised while contributing HKT registrations: unknown variance :sideways'
        end
      end.new
    end

    before do
      allow(Rigor::Inference::HktRegistry).to receive(:scan_rbs_loader).and_call_original
      allow(Rigor::Environment).to receive(:for_project).and_wrap_original do |original, **kwargs|
        original.call(**kwargs, plugin_registry: raising_plugin_registry)
      end
    end

    it "does not raise out of the run, and reports one overlay-worded :error row" do
      result = nil
      expect { result = analyze(source, cache_store: nil) }.not_to raise_error

      rows = result.diagnostics.select { |d| d.rule == "rbs.coverage.hkt-scan-failed" }
      expect(rows.size).to eq(1)
      expect(rows.first.severity).to eq(:error)
      expect(rows.first.path).to eq(".rigor.yml")
      expect(rows.first.message).to start_with("Building the plugin HKT overlay raised")
      expect(rows.first.message).to include("ArgumentError", 'plugin "hktboom"', "unknown variance :sideways")
      # The scan wording would send the reader to a `.rbs` that is not the problem.
      expect(rows.first.message).not_to include("The implicit HKT scan over RBS `type` aliases raised")
    end

    it "keeps the file's real diagnostics and emits no per-file crash row" do
      result = analyze(source, cache_store: nil)

      expect(result.diagnostics.map(&:rule)).to include("call.undefined-method")
      expect(result.diagnostics.map(&:message))
        .to satisfy("no diagnostic starting with the check-rule prefix") do |messages|
          messages.none? { |m| m.start_with?("internal analyzer error") }
        end
    end

    # The scan still runs on top of the bundled registrations after the overlay is dropped — the
    # degradation is one step narrower than the scan stage's, and this is what says so.
    it "still runs the RBS `type`-alias scan" do
      analyze(source, cache_store: nil)

      expect(Rigor::Inference::HktRegistry).to have_received(:scan_rbs_loader).at_least(:once)
    end

    # The run-owned demand (`PoolCoordinator#hkt_scan_outcome`, after the file loop) is the site the #791
    # follow-up measured raising: a file that never calls a `Klass.method` demands nothing, so the
    # coordinator's own demand is the only one — and it sits outside every rescue.
    it "reports the row from the run's own demand when no analysed file demands the registry" do
      result = nil
      expect { result = analyze("x = 1\n", cache_store: nil) }.not_to raise_error

      expect(result.diagnostics.map(&:rule)).to include("rbs.coverage.hkt-scan-failed")
    end

    # The third path the follow-up measured. A pool worker demands the registry at drain time, and the
    # coordinator demands its own after the loop; both were raising, and a fork worker's raise is a dead
    # worker rather than a diagnostic. The row must arrive exactly once, worded the same as sequential.
    it "reports the row once under the worker pool" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "code.rb"), source)
        # A second file so the run has something to spread across workers, and so a per-worker row would
        # show up as a duplicate rather than hiding behind the coordinator's own demand.
        File.write(File.join(dir, "other.rb"), "JSON.parse(\"[]\")\n")
        configuration = Rigor::Configuration.new("paths" => [dir])

        result = Dir.chdir(dir) do
          guarded_run(Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil, workers: 2))
        end

        rows = result.diagnostics.select { |d| d.rule == "rbs.coverage.hkt-scan-failed" }
        expect(rows.size).to eq(1)
        expect(rows.first.message).to start_with("Building the plugin HKT overlay raised")
        expect(result.diagnostics.map(&:rule)).to include("call.undefined-method")
      end
    end
  end
end
