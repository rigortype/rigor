# frozen_string_literal: true

require "spec_helper"

require "rigor/analysis/diagnostic"
require "rigor/analysis/result"
require "rigor/protection/analysis_guard"

# Issue #686 — the seam both ADR-69 kill oracles route every analysis through. A kill is decided by SET
# DIFFERENCE between a baseline run's diagnostics and a mutant's, so a run whose diagnostics say nothing
# about the code must be refused rather than compared: a crashed check rule leaves the identical synthetic
# row on both sides, the difference is empty, and the mutant is scored a SURVIVOR instead of indeterminate.
#
# What this file pins is the LINE between "refuse" and "still measure", because getting it wrong in either
# direction inflates the harness's headline signal. The review of the first cut armed too much: refusing the
# plugin-isolation row took a real `killed=1 survived=6` measurement to `killed=0 survived=0`, and since a
# raising `#prepare` appends its row to every sequential run, it would have refused every run for the life
# of the process.
RSpec.describe Rigor::Protection::AnalysisGuard do
  def diagnostic(message:, severity: :error, rule: nil, source_family: :builtin)
    Rigor::Analysis::Diagnostic.new(
      path: "app.rb", line: 1, column: 1, message: message,
      severity: severity, rule: rule, source_family: source_family
    )
  end

  def real_finding
    diagnostic(message: "undefined method `x'", rule: "call.undefined-method")
  end

  def result(*diagnostics)
    Rigor::Analysis::Result.new(diagnostics: diagnostics)
  end

  it "hands back the diagnostics of a healthy run" do
    healthy = result(real_finding)

    expect(described_class.checked(healthy, context: "spec")).to equal(healthy.diagnostics)
  end

  # The check-rule rescue wraps the whole per-file body, so `[crash_row]` is all that comes back — the real
  # findings are gone, and comparing two of these reports agreement about nothing.
  it "refuses a run whose file analysis was replaced by a crash row" do
    crashed = result(diagnostic(message: "internal analyzer error: RuntimeError: boom"))

    expect { described_class.checked(crashed, context: "DiagnosticOracle re-analysis of a.rb") }
      .to raise_error(Rigor::Protection::AnalyzerCrashed, /internal analyzer error/)
  end

  it "names the seam and the shape it saw, so the raise points somewhere" do
    crashed = result(diagnostic(message: "internal analyzer error: RuntimeError: boom"))

    expect { described_class.checked(crashed, context: "ClosureKillOracle closure analysis of a.rb") }
      .to raise_error(Rigor::Protection::AnalyzerCrashed, /ClosureKillOracle closure analysis of a\.rb.*check_rule/m)
  end

  # Issue #686 review, F2 — the measurement-preserving half, and the reason this is not simply "refuse
  # anything that looks like a failure". `collect_plugin_diagnostics` replaces only the raising plugin's
  # contribution; `CheckRules.diagnose` has already returned, so the run still carries every builtin rule's
  # findings and is still a measurement.
  it "still measures a run carrying the plugin-isolation row, findings and all" do
    plugin_row = diagnostic(message: "plugin `demo` raised", rule: "runtime-error", source_family: :plugin_loader)
    finding = real_finding
    measured = result(finding, plugin_row)

    expect(described_class.checked(measured, context: "spec")).to eq([finding, plugin_row])
  end

  # The same reasoning one tier further out: an RBS build failure means every rule ran over a smaller type
  # universe, which is a degradation the run reports about itself, not an absence of analysis. The site
  # filter that admits mutations already drops receivers whose type did not resolve, so a class whose
  # definition failed contributes no measured sites to begin with.
  it "still measures a run carrying an RBS build-failure warning" do
    Rigor::Analysis::CrashSignature::RBS_BUILD_FAILURE_RULES.each do |rule|
      degraded = result(real_finding, diagnostic(message: "…", severity: :warning, rule: rule))

      expect(described_class.checked(degraded, context: "spec").size).to eq(2)
    end
  end
end
