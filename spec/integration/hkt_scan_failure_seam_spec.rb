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
  describe "suppressibility" do
    it "is removed by an exact severity_overrides: off" do
      result = analyze(source, config: { "severity_overrides" => { "rbs.coverage.hkt-scan-failed" => "off" } })
      expect(result.diagnostics.map(&:rule)).not_to include("rbs.coverage.hkt-scan-failed")
    end

    it "is removed by the rbs family severity_overrides: off" do
      result = analyze(source, config: { "severity_overrides" => { "rbs" => "off" } })
      expect(result.diagnostics.map(&:rule)).not_to include("rbs.coverage.hkt-scan-failed")
    end

    it "is NOT removed by disable:" do
      result = analyze(source, config: { "disable" => ["rbs.coverage.hkt-scan-failed"] })
      rows = result.diagnostics.select { |d| d.rule == "rbs.coverage.hkt-scan-failed" }
      expect(rows.size).to eq(1)
      expect(rows.first.severity).to eq(:error)
    end
  end
end
